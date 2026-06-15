import 'dart:async';

import 'package:advertising_id/advertising_id.dart';
import 'package:connection_notifier/connection_notifier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show ConsentStatus, DebugGeography;

import '../adapters/admob_adapter.dart';
import '../adapters/applovin_adapter.dart';
import '../config/ad_config.dart';
import '../consent/consent_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';
import '../vip/_first_install_guard.dart';
import '../vip/vip_manager.dart';
import '../widget/ad_loading_dialog.dart';
import 'ad_consent.dart';
import 'att_consent.dart';
import 'ad_provider_adapter.dart';
import 'ad_route_observer.dart';
import 'ad_safety_config.dart';
import 'event_bus.dart';
import 'ump_consent.dart';

/// Orchestrator singleton.
///
/// Holds no provider-specific state — that lives inside [AdProviderAdapter]
/// implementations. [AdManager] owns:
///  - active adapter
///  - lifecycle observer (`WidgetsBindingObserver`)
///  - VIP gate (via [VipManager])
///  - safety gate (`AdSafetyConfig`)
///  - splash flag + count
///  - navigator key for SDK-driven dialogs
///  - periodic retry timer
///  - consent flags propagation
///  - [events] stream broadcasting [AdEvent]s
///  - splash budget enforcement (Q32E)
class AdManager with WidgetsBindingObserver {
  AdManager._internal() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _processStartedAtMs = ts;
    // Logger config not yet set at this point (initialize() hasn't run),
    // so use direct print prefixed with the SafeLogger tag prefix so it
    // shows up in the same `roy93~` stream the rest of the SDK uses.
    // ignore: avoid_print
    print('roy93~ [$_tag] 🚀 AdManager singleton CREATED — '
        'new Flutter process / cold start at ${DateTime.fromMillisecondsSinceEpoch(ts).toIso8601String()}');
    _ensureObserverAdded();
  }

  static final AdManager _instance = AdManager._internal();

  /// Wall-clock timestamp of when this singleton (and therefore this
  /// Flutter process) was created. Useful for distinguishing a true cold
  /// start from a lifecycle resume — if you see two `🚀 CREATED` markers in
  /// the same logcat session, Android killed the process between them
  /// (likely under memory pressure, with the user perceiving a "black
  /// screen → fresh splash" flow).
  ///
  /// Nullable + 0 fallback (project convention forbids `late` and `!`).
  /// In practice always set during the singleton constructor before any
  /// other code can read it.
  int? _processStartedAtMs;

  int get processStartedAtMs => _processStartedAtMs ?? 0;

  factory AdManager() => _instance;

  static const String _tag = 'AdManager';
  static const int _retryIntervalMs = 5 * 60 * 1000;

  // ─── Config + adapter ────────────────────────────────────────────────────

  AdConfig? _config;
  AdProviderAdapter? _adapter;
  VipManager? _vipManager;
  ConsentManager? _consentManager;
  AdConsent _consent = AdConsent.conservative;

  AdConfig? get config => _config;

  bool get isInitialised => _config != null && _adapter != null;

  bool get isAdMobProvider => _config?.isAdMob ?? false;

  AdProviderAdapter? get adapter => _adapter;

  /// Release-build footgun checks, returned as human-readable warnings.
  /// `initialize()` logs each (and asserts in non-release). Pure + static so it
  /// is unit-testable without running the full native init.
  @visibleForTesting
  static List<String> releaseFootgunWarnings(AdConfig config,
      {required bool isDebug}) {
    if (isDebug) return const [];
    final warnings = <String>[];
    // dryRun disables the ENTIRE safety layer (throttle, caps, CTR fraud).
    if (config.safety.dryRun) {
      warnings.add('🚨 AdSafetyParams.dryRun is TRUE in a RELEASE build — the '
          'entire safety layer is bypassed. This risks an AdMob/AppLovin ban. '
          'Set dryRun:false before shipping.');
    }
    // Google public TEST unit IDs must never serve in production AdMob.
    if (config.provider == AdProvider.admob) {
      const googleTestPrefix = 'ca-app-pub-3940256099942544';
      final m = config.admob;
      final usesTestId = m != null &&
          (m.bannerId.contains(googleTestPrefix) ||
              m.interstitialId.contains(googleTestPrefix) ||
              m.appOpenId.contains(googleTestPrefix) ||
              m.rewardedId.contains(googleTestPrefix));
      if (usesTestId) {
        warnings.add('🚨 AdMob provider is active in RELEASE with Google TEST '
            'ad unit IDs (ca-app-pub-3940256099942544/…). Serving test ads in '
            'production violates AdMob policy and earns \$0. Replace with '
            'production unit IDs before shipping.');
      }
    }
    return warnings;
  }

  /// VIP manager — `null` until [initialize] completes.
  VipManager? get vip => _vipManager;

  // ─── Test seams ────────────────────────────────────────────────────────────
  /// Push an event onto [events] (lets a test drive consumers like RevenuePanel
  /// without a live native adapter).
  @visibleForTesting
  void debugEmit(AdEvent event) => _emit(event);

  /// Inject a (fake) adapter so the gating logic in `loadX`/`showX`/`canShowX`
  /// can be unit-tested without the native plugins.
  @visibleForTesting
  void debugSetAdapter(AdProviderAdapter? adapter) => _adapter = adapter;

  /// Inject a VipManager so the VIP-suppression branches are unit-testable.
  @visibleForTesting
  set debugVipManager(VipManager? m) => _vipManager = m;

  /// Consent manager — `null` until [initialize] completes. Owns the
  /// Cupertino consent dialog, persistence, and provider apply pipeline.
  /// Also accessible via static [ConsentManager.instance] once initialised.
  ConsentManager? get consentManager => _consentManager;

  /// Active consent flags. Default conservative until [setConsent] is called.
  AdConsent get consent => _consent;

  /// Stream of every [AdEvent] (load / show / click / reward / revenue).
  Stream<AdEvent> get events => _eventStream.stream;
  final StreamController<AdEvent> _eventStream =
      StreamController<AdEvent>.broadcast();

  /// Increments on every successful [initialize]. Widgets can listen so they
  /// rebuild after a provider hot-swap or destroy → re-init cycle.
  final ValueNotifier<int> initRevision = ValueNotifier<int>(0);

  // ─── Common state ────────────────────────────────────────────────────────

  String _currentDeviceGAID = '';

  /// True if the current device is a VIP — combines VipManager state and the
  /// legacy GAID set (auto-migrated on first init, kept for 1.x parity).
  bool get _isVipMember => _vipManager?.isActive ?? false;

  bool _isSplashActive = true;
  int _countInitSplashScreen = 0;

  bool _isInitializing = false;
  int _lastFullscreenDismissAt = 0;

  /// Re-entrancy guard for [showRewardedAd] — spans the on-demand load + show
  /// window so a second tap can't start a parallel loader/show. Reset in the
  /// rewarded `onDone`, on the on-demand-fail path, and in [destroy].
  bool _rewardedInFlight = false;

  /// Per-slot previous state, used by [_fullscreenDismissWatcher] to detect
  /// `showing → !showing` transitions. The slot watcher is the authoritative
  /// source for [_lastFullscreenDismissAt] — adapter-callback writes are kept
  /// as belt-and-braces fallbacks but become redundant.
  final Map<AdSlotType, AdSlotState> _slotPrevState = {};
  final List<VoidCallback> _slotWatcherDisposers = [];

  GlobalKey<NavigatorState>? _navigatorKey;

  int _lastBannerLoadAt = 0;
  static const int _bannerLoadCooldownMs = 5000;

  bool _retryTimerActive = false;
  int _retryGen = 0;

  bool _isObserverAdded = false;

  void _ensureObserverAdded() {
    if (_isObserverAdded) return;
    WidgetsBinding.instance.addObserver(this);
    _isObserverAdded = true;
  }

  Timer? _resumeFallbackTimer;

  /// Splash budget timer (Q32E) — fires `markSplashInactive` if the splash
  /// flow exceeds [AdConfig.splashMaxDuration].
  Timer? _splashBudgetTimer;

  // ─── Splash flow accessors ───────────────────────────────────────────────

  void markSplashActive() {
    _isSplashActive = true;
    SafeLogger.d(_tag, 'markSplashActive');
    _armSplashBudget();
  }

  void markSplashInactive() {
    _isSplashActive = false;
    _splashBudgetTimer?.cancel();
    _splashBudgetTimer = null;
    SafeLogger.d(_tag, 'markSplashInactive');
    // Splash is done — schedule the deferred consent dialog so it lands on
    // whatever screen the host navigates to next (typically home), without
    // fighting the splash flow.
    _maybeScheduleConsentDialog();
  }

  bool _consentDialogScheduled = false;

  /// Schedule the auto-show consent dialog for the post-splash window.
  /// Idempotent — first scheduling wins per init cycle. Caller can defeat
  /// this by manually calling `consentManager.showDialog` earlier (which
  /// flips `hasBeenAsked` true and the scheduled show becomes a noop).
  ///
  /// VIP users are skipped: they won't see any ads regardless of consent
  /// flags, so prompting them adds friction without compliance benefit.
  /// (E.g., the first-install 24h VIP grace makes the very first session
  /// ad-free — no need to ask consent before the user has even seen an ad.)
  void _maybeScheduleConsentDialog() {
    final cfg = _config;
    final mgr = _consentManager;
    if (cfg == null || mgr == null) return;
    if (!cfg.autoShowConsentDialog) return;
    if (mgr.hasBeenAsked) return;
    if (_consentDialogScheduled) return;
    if (_isVipMember) {
      SafeLogger.d(
          _tag, '⏭️ consent dialog skipped — VIP member (no ads anyway)');
      return;
    }
    _consentDialogScheduled = true;

    final delay = cfg.consentDialogPostSplashDelay;
    SafeLogger.d(_tag,
        () => '🕒 consent dialog scheduled (delay=${delay.inMilliseconds}ms)');
    Future.delayed(delay, () async {
      if (mgr.hasBeenAsked) {
        SafeLogger.d(
            _tag, '⏭️ scheduled consent dialog skipped — already asked');
        return;
      }
      // Re-check VIP at fire time — user may have redeemed a VIP key during
      // the 1 s window between schedule and fire.
      if (_isVipMember) {
        SafeLogger.d(_tag, '⏭️ scheduled consent dialog skipped — became VIP');
        return;
      }
      final ctx = _navigatorKey?.currentContext;
      if (ctx == null) {
        SafeLogger.w(
            _tag, 'scheduled consent dialog: no navigator context — skipping');
        return;
      }
      SafeLogger.d(_tag, '🪟 showing scheduled consent dialog');
      await mgr.showDialog(
        ctx, // ignore: use_build_context_synchronously
        config: cfg,
        barrierDismissible: cfg.consentBarrierDismissible,
      );
      _consent = mgr.adConsent;
    });
  }

  bool get isSplashActive => _isSplashActive;

  int get countInitSplashScreen => _countInitSplashScreen;

  void incrementSplashCount() {
    _countInitSplashScreen++;
    SafeLogger.d(_tag, () => 'incrementSplashCount → $_countInitSplashScreen');
  }

  /// Hard cap applied AFTER the soft splash budget elapses while a splash
  /// app-open ad is still showing. App-open ads cap themselves at ~30 s
  /// natively; we give a generous +30 s window so the user can finish the
  /// ad before we force-nav.
  static const Duration _splashHardCapAfterAd = Duration(seconds: 30);

  void _armSplashBudget() {
    final cfg = _config;
    final dur = cfg?.splashMaxDuration ?? const Duration(seconds: 8);
    _splashBudgetTimer?.cancel();
    _splashBudgetTimer = Timer(dur, _onSplashBudgetElapsed);
  }

  void _onSplashBudgetElapsed() {
    _splashBudgetTimer = null;
    if (!_isSplashActive) return;
    // If the splash app-open ad is currently showing the user is mid-ad —
    // forcing markSplashInactive here cuts the ad off and the splash flow's
    // own onAdDismiss → markSplashInactive becomes a noop. Wait instead.
    if (_adapter?.appOpenSlot.value == AdSlotState.showing) {
      SafeLogger.d(
          _tag,
          () =>
              '⏰ splash budget elapsed but app-open in flight — re-arming +${_splashHardCapAfterAd.inSeconds}s');
      _splashBudgetTimer = Timer(_splashHardCapAfterAd, () {
        _splashBudgetTimer = null;
        if (!_isSplashActive) return;
        SafeLogger.w(
            _tag, '⏰ splash hard cap reached — forcing markSplashInactive');
        markSplashInactive();
      });
      return;
    }
    final dur = _config?.splashMaxDuration ?? const Duration(seconds: 8);
    SafeLogger.w(_tag,
        '⏰ splash budget exceeded (${dur.inSeconds}s) — forcing markSplashInactive');
    markSplashInactive();
  }

  // ─── Navigator key ───────────────────────────────────────────────────────

  void setNavigatorKey(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
    SafeLogger.d(_tag, 'setNavigatorKey ✅');
  }

  GlobalKey<NavigatorState>? get navigatorKey => _navigatorKey;

  // ─── Banner accessors used by BannerAdWidget ─────────────────────────────

  bool canLoadBanner() {
    if (_lastBannerLoadAt == 0) return true;
    return DateTime.now().millisecondsSinceEpoch - _lastBannerLoadAt >=
        _bannerLoadCooldownMs;
  }

  void recordBannerLoad() {
    _lastBannerLoadAt = DateTime.now().millisecondsSinceEpoch;
  }

  ValueListenable<bool> get bannerIsLoaded =>
      _adapter?.banner.isLoaded ?? _stubBoolFalse;

  ValueListenable<bool> get bannerHasError =>
      _adapter?.banner.hasError ?? _stubBoolFalse;

  ValueListenable<Size?> get bannerAdSize =>
      _adapter?.banner.adSize ?? _stubSize;

  ValueListenable<bool> get bannerAutoRefreshEnabled =>
      _adapter?.banner.autoRefreshEnabled ?? _stubBoolTrue;

  ValueListenable<bool> get bannerVisible =>
      _adapter?.banner.visible ?? _stubBoolTrue;

  ValueListenable<Object?> get bannerAdViewId =>
      _adapter?.appLovinBannerAdViewId ?? _stubObject;

  String get appLovinBannerId => _adapter?.appLovinBannerId ?? '';

  bool get bannerRoutePaused => _adapter?.bannerRoutePaused ?? false;

  void setBannerRoutePaused(bool paused) =>
      _adapter?.setBannerRoutePaused(paused);

  Widget? get admobBannerView => _adapter?.buildAdmobBannerView();

  static final ValueNotifier<bool> _stubBoolFalse = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> _stubBoolTrue = ValueNotifier<bool>(true);
  static final ValueNotifier<Size?> _stubSize = ValueNotifier<Size?>(null);
  static final ValueNotifier<Object?> _stubObject =
      ValueNotifier<Object?>(null);

  // ──────────────────────────────────────────────────────────────────────────
  //  INITIALIZE
  // ──────────────────────────────────────────────────────────────────────────

  /// Initialise the SDK. Idempotent: calling twice without [destroy] auto-cleans
  /// the previous adapter first.
  ///
  /// Wires:
  /// 1. [SafeLogger] from `config.logLevel/logTagFilter/onLog`.
  /// 2. [AdSafetyConfig] from `config.safety` (Phase 3).
  /// 3. [VipManager] (Phase 4) — loads + auto-migrates legacy GAID list.
  /// 4. Adapter (`AdMobAdapter` or `AppLovinAdapter`).
  /// 5. App Open + secondary preload.
  /// 6. Periodic retry timer.
  ///
  /// `onComplete(success, gaid)` mirrors 1.x callback contract.
  Future<void> initialize({
    required AdConfig config,
    required void Function(bool success, String gaid) onComplete,
  }) async {
    // Guard FIRST so concurrent calls during a teardown-then-reinit cycle
    // can't slip past `_disposeAdapter`'s await and leak two adapters.
    if (_isInitializing) {
      SafeLogger.w(_tag, 'initialize already in progress — skipping duplicate');
      return;
    }
    _isInitializing = true;
    // Wrap the entire init body in try/finally so a thrown
    // `AdPreferences.getInstance` / `AdSafetyConfig.init` / `VipManager.load`
    // can't strand `_isInitializing=true` and block future inits.
    try {
      if (isInitialised) {
        SafeLogger.w(_tag, 'initialize called again — auto-disposing previous');
        await _disposeAdapter();
      }

      // Phase 2: configure logger first so init logs respect the level.
      SafeLogger.configure(
        level: config.logLevel,
        tagFilter: config.logTagFilter,
        onLog: config.onLog,
      );

      _ensureObserverAdded();
      SafeLogger.d(
          _tag, () => 'initialize start, provider=${config.provider.name}');

      final prefs = await AdPreferences.getInstance();

      // Phase 3: pipe safety params from config.
      await AdSafetyConfig.init(prefs, params: config.safety);

      // ── Release footguns (loud, fire in release where it matters) ──────────
      for (final w in releaseFootgunWarnings(config, isDebug: kDebugMode)) {
        SafeLogger.e(_tag, w);
        assert(false, w);
      }

      // Resolve device GAID FIRST — VIP migration + first-init both need it
      // to preserve 1.x's per-device matching semantic (a `vipDeviceGaids`
      // entry only marks the device VIP when its own GAID matches).
      try {
        final id = await AdvertisingId.id(true);
        _currentDeviceGAID = id ?? '';
      } on PlatformException catch (e) {
        SafeLogger.w(_tag, () => 'GAID PlatformException: $e');
      } catch (e) {
        SafeLogger.w(_tag, () => 'GAID error: $e');
      }
      SafeLogger.d(_tag, () => 'GAID=$_currentDeviceGAID');

      // Phase 4: load VIP manager + auto-migrate (matched against this GAID).
      // Detach + dispose any pre-existing VipManager (re-init path) before
      // wiring a new one — otherwise the old listener would leak.
      _vipManager?.activeListenable.removeListener(_onVipActiveChanged);
      final vip = VipManager(prefs, maxStackDuration: config.maxVipStackDuration);
      await vip.load(currentDeviceGaid: _currentDeviceGAID);
      vip.activeListenable.addListener(_onVipActiveChanged);
      _vipManager = vip;
      SafeLogger.d(_tag,
          () => 'VIP active=${vip.isActive} entries=${vip.entries.length}');

      // First-init: import VIP GAIDs from config (release builds only).
      // Only entries whose GAID matches THIS device are persisted as active
      // VIP — matching 1.x behaviour exactly.
      if (!prefs.isAddVIPMemberFirstInitSuccess()) {
        if (!kDebugMode && config.vipDeviceGaids.isNotEmpty) {
          final myGaid = _currentDeviceGAID.trim().toUpperCase();
          for (final gaid in config.vipDeviceGaids) {
            if (gaid.trim().isEmpty) continue;
            if (gaid.trim().toUpperCase() != myGaid) continue;
            await vip.addVip(
              key: 'CONFIG_${gaid.trim()}',
              duration: const Duration(days: 365 * 50),
            );
          }
          await prefs.addVIPMemberFirstInitSuccess();
        }
      }

      // First-install VIP grace. Fires once per install — see
      // [AdConfig.firstInstallVipGrace] for the rationale and limitations.
      // Stamp the install time even when grace is disabled, so analytics /
      // future features can read it via prefs.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await prefs.setFirstInstallAtMsIfMissing(nowMs);
      final graceCfg = config.firstInstallVipGrace;
      if (graceCfg.isEnabled && !prefs.isFirstInstallGraceApplied()) {
        final dur = graceCfg.duration;
        if (dur != null) {
          // Anti-uninstall-bypass guard. iOS: a Keychain flag persists
          // across uninstall, so the second install sees the flag and we
          // skip re-granting. Android: Install Referrer with conservative
          // skip on connection failure (Q3). Falls through to allow grace
          // if no bypass signal is found, so legitimate first-time users
          // still get their grace window.
          final guard = FirstInstallGuard();
          final alreadyGranted = await guard.hasAlreadyGranted();
          if (alreadyGranted) {
            await prefs.markFirstInstallGraceApplied();
            SafeLogger.d(
                _tag,
                () => '🛡️ first-install VIP grace SKIPPED — anti-bypass guard '
                    'returned true (prior install detected, or referrer signal '
                    'inconclusive on Android)');
          } else {
            await vip.addVip(
              key: config.firstInstallVipKey,
              duration: dur,
            );
            // ORDER MATTERS — write the persistent anti-bypass marker
            // (Keychain on iOS) BEFORE the per-install prefs flag. If the
            // process is force-killed between these two writes, the worst
            // case is that the prefs flag stays unset — and the next init
            // on the same install simply re-runs the guard, which finds
            // the Keychain flag and skips re-granting (or, if the user
            // also uninstalls in that microsecond window before reinstall,
            // the Keychain flag still blocks the bypass).
            //
            // The opposite order would leave a window where prefs flag
            // is set but Keychain flag is not, allowing uninstall +
            // reinstall to bypass the guard.
            await guard.markGranted();
            await prefs.markFirstInstallGraceApplied();
            SafeLogger.d(_tag, () {
              // Log seconds in debug (likely 30 s) so QA can verify quickly;
              // hours in release (24 h+) for human-readable retention reports.
              final readable =
                  dur.inHours > 0 ? '${dur.inHours}h' : '${dur.inSeconds}s';
              return '🎁 first-install VIP grace granted ($readable, mode=${kDebugMode ? "debug" : "release"})';
            });
          }
        }
      }

      // Pick adapter, wire its event sink, then initialise. The resolved
      // GAID is forwarded so the AppLovin adapter can register this device
      // as a test device in debug builds (preserves 1.x policy compliance).
      final adapter = config.isAdMob ? AdMobAdapter() : AppLovinAdapter();
      adapter.eventSink = _emit;
      final ok =
          await adapter.initialize(config, deviceGaid: _currentDeviceGAID);
      if (!ok) {
        SafeLogger.e(_tag, 'adapter init FAILED');
        onComplete(false, _currentDeviceGAID);
        SimpleEventBus().fire(const BoolEvent(false));
        return;
      }

      _config = config;
      _adapter = adapter;
      _attachFullscreenDismissWatchers();
      initRevision.value = initRevision.value + 1;

      // Phase 5+: bootstrap ConsentManager (loads persisted user choice from
      // prefs). If config asks for auto-show AND user hasn't been asked yet,
      // present the Cupertino dialog before the first ad request. The dialog
      // result auto-applies to providers via ConsentManager.set.
      final consentMgr = await ConsentManager.bootstrap(
        prefs: prefs,
        strings: config.consentDialogStrings,
      );
      _consentManager = consentMgr;
      _consent = consentMgr.adConsent;

      // Auto-show is DEFERRED: showing the dialog mid-`initialize()` would
      // block the splash flow and steal user attention from the splash app
      // open ad. Instead we schedule it for `markSplashInactive` + delay,
      // which fires after the splash → home navigation has settled. See
      // [_maybeScheduleConsentDialog].

      // Apply consent flags BEFORE the first ad request so AdMob's
      // RequestConfiguration (COPPA tag, test devices) and AppLovin's
      // privacy flags are in effect for the very first impression.
      // Awaited (not fire-and-forget) — otherwise the loadAppOpenAd microtask
      // below could race with `MobileAds.instance.updateRequestConfiguration`
      // and the first request would go out without the privacy tags.
      await consentMgr.applyToProviders(config: _config);

      onComplete(true, _currentDeviceGAID);
      SimpleEventBus().fire(const BoolEvent(true));

      SafeLogger.d(_tag, 'triggering App Open + banner preload');
      unawaited(loadAppOpenAd());
      // Banner preload also respects VIP — preloading while VIP is active
      // wastes a network request, and on AppLovin it inflates the internal
      // `recordBannerImpression` counter (the banner widget itself does
      // suppress *display*, but the cache fill is unnecessary).
      if (_isVipMember) {
        SafeLogger.d(_tag, '⏭️ banner preload skipped — VIP member');
      } else {
        unawaited(adapter.preloadBanner());
      }

      _scheduleFirstSecondaryLoad();
      _startAdRetryTimer();
    } catch (e, st) {
      SafeLogger.e(_tag, 'initialize THREW: $e\n$st');
      onComplete(false, _currentDeviceGAID);
      SimpleEventBus().fire(const BoolEvent(false));
    } finally {
      _isInitializing = false;
    }
  }

  /// Fired when [VipManager.activeListenable] flips. We only care about the
  /// `true → false` transition (VIP expired or got revoked mid-session) —
  /// when it fires, kick all four ad slots into preload so the user doesn't
  /// see "ad not ready" on the very first show after losing VIP.
  ///
  /// Without this, a freshly-non-VIP user would have to wait for the next
  /// retry-timer tick (5 minutes) for inter/rewarded to appear, because
  /// `_scheduleFirstSecondaryLoad` only fires after the App Open slot
  /// transitions to ready — which never happens during a VIP session.
  void _onVipActiveChanged() {
    final vip = _vipManager;
    final ad = _adapter;
    if (vip == null || ad == null) return;
    if (vip.isActive) {
      SafeLogger.d(_tag, '🔒 VIP active — ad loads suppressed');
      return;
    }
    SafeLogger.d(_tag, '🔓 VIP inactive — kicking secondary preload');
    unawaited(loadAppOpenAd());
    unawaited(loadInterstitial());
    unawaited(loadRewardedAd());
    unawaited(ad.preloadBanner());
  }

  /// Attach listeners to the three fullscreen slots so we can record the real
  /// dismiss instant (when state transitions OUT of [AdSlotState.showing]).
  /// This is the source of truth for [_lastFullscreenDismissAt] used by the
  /// app-open-on-resume guard — replacing the brittle adapter-callback writes
  /// that fired at the wrong moment for rewarded ads (rewarded `onDone` is
  /// called when the reward is earned, not when the ad is actually dismissed,
  /// causing the 2 s guard to leak through after a 30 s rewarded video).
  void _attachFullscreenDismissWatchers() {
    final ad = _adapter;
    if (ad == null) return;
    final slots = [ad.appOpenSlot, ad.interstitialSlot, ad.rewardedSlot];
    for (final slot in slots) {
      _slotPrevState[slot.type] = slot.value;
      void listener() {
        final prev = _slotPrevState[slot.type];
        final curr = slot.value;
        if (prev == AdSlotState.showing && curr != AdSlotState.showing) {
          _lastFullscreenDismissAt = DateTime.now().millisecondsSinceEpoch;
          SafeLogger.d(
              _tag,
              () =>
                  '🛡️ ${slot.type.name} dismissed — app-open suppression armed');
        }
        _slotPrevState[slot.type] = curr;
      }

      slot.state.addListener(listener);
      _slotWatcherDisposers.add(() => slot.state.removeListener(listener));
    }
  }

  void _detachFullscreenDismissWatchers() {
    for (final dispose in _slotWatcherDisposers) {
      try {
        dispose();
      } catch (_) {}
    }
    _slotWatcherDisposers.clear();
    _slotPrevState.clear();
  }

  bool _isFirstAdLoadTriggered = false;

  void _scheduleFirstSecondaryLoad() {
    if (_isFirstAdLoadTriggered) return;
    final ad = _adapter;
    if (ad == null) return;
    ad.appOpenSlot.state.addListener(_onAppOpenStateChange);
  }

  void _onAppOpenStateChange() {
    final ad = _adapter;
    if (ad == null) return;
    final s = ad.appOpenSlot.value;
    if (s == AdSlotState.ready || s == AdSlotState.cooldown) {
      if (_isFirstAdLoadTriggered) return;
      _isFirstAdLoadTriggered = true;
      ad.appOpenSlot.state.removeListener(_onAppOpenStateChange);
      SafeLogger.d(_tag, 'first secondary load → inter + rewarded');
      unawaited(loadInterstitial());
      unawaited(loadRewardedAd());
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  CONSENT (Phase 5)
  // ──────────────────────────────────────────────────────────────────────────

  /// Update privacy / consent flags. Forwards to both providers.
  ///
  /// Call this after running your consent UI (e.g. UMP form for AdMob).
  /// Default value before the first call is [AdConsent.conservative]
  /// (non-personalized ads everywhere).
  Future<void> setConsent(AdConsent consent) async {
    _consent = consent;
    SafeLogger.d(_tag, () => 'setConsent: $consent');
    if (!isInitialised) {
      SafeLogger.d(_tag,
          '⏭️ setConsent: SDK not initialised — buffering for next initialize()');
      return;
    }
    await applyConsentToProviders(consent, config: _config);
  }

  /// Run Google's UMP (User Messaging Platform) consent flow and auto-apply
  /// the result. Wraps [requestUmpConsentFlow] — see its doc for details.
  ///
  /// Typical usage in splash, before [initialize]:
  /// ```dart
  /// final r = await AdManager().requestUmpConsent();
  /// if (r.canRequestAds) {
  ///   await AdManager().initialize(config: ...);
  /// }
  /// ```
  ///
  /// On success, the result is mapped to [AdConsent] and applied via
  /// [setConsent] (no-op if init hasn't run yet — flags are buffered for the
  /// next [initialize]).
  Future<UmpConsentResult> requestUmpConsent({
    bool testMode = false,
    DebugGeography? debugGeography,
    List<String> testIdentifiers = const [],
    bool tagForUnderAgeOfConsent = false,
  }) async {
    final result = await requestUmpConsentFlow(
      testMode: testMode,
      debugGeography: debugGeography,
      testIdentifiers: testIdentifiers,
      tagForUnderAgeOfConsent: tagForUnderAgeOfConsent,
    );
    // Map UMP status → AdConsent.hasUserConsent. `obtained` and `notRequired`
    // both mean we may serve personalized ads; `required` (form not shown /
    // dismissed without choosing) and `unknown` stay non-personalized.
    final hasConsent = result.status == ConsentStatus.obtained ||
        result.status == ConsentStatus.notRequired;
    await setConsent(AdConsent(
      hasUserConsent: hasConsent,
      isAgeRestrictedUser: _consent.isAgeRestrictedUser,
      doNotSell: _consent.doNotSell,
    ));
    return result;
  }

  /// Show the iOS App Tracking Transparency prompt when needed and return the
  /// resulting authorization. No-op on non-iOS (returns
  /// [AttStatus.notSupported]). Wraps [requestAttIfNeeded] — see its doc.
  ///
  /// Call this from your splash **before** [requestUmpConsent] so the IDFA
  /// availability is settled before the first ad request. Requires
  /// `NSUserTrackingUsageDescription` in `Info.plist`.
  ///
  /// This does **not** mutate the GDPR consent flag: ATT (IDFA access) and UMP
  /// (GDPR purposes) are independent signals, and the native AppLovin/AdMob
  /// SDKs already read the ATT status directly when deciding IDFA usage.
  /// Tightening [setConsent] here would wrongly suppress EEA personalization
  /// for a user who granted GDPR consent but declined ATT.
  Future<AttResult> requestAtt() async {
    final result = await requestAttIfNeeded();
    SafeLogger.d(_tag, () => 'ATT → ${result.status.name}');
    return result;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  DESTROY
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> destroy() async {
    SafeLogger.d(_tag, 'destroy() called');
    await _disposeAdapter();
    // Bump revision so subscribed widgets rebuild against the now-null adapter
    // (otherwise BannerAdWidget would keep painting the stale provider's view
    // until something else triggers a rebuild).
    initRevision.value = initRevision.value + 1;
    _resumeFallbackTimer?.cancel();
    _resumeFallbackTimer = null;
    _splashBudgetTimer?.cancel();
    _splashBudgetTimer = null;
    _stopAdRetryTimer();
    AdLoadingDialog.resetState();
    AdScreenRouteLogger.resetState();
    AdSafetyConfig.resetForReinit();
    SimpleEventBus().clearAll();

    _vipManager?.activeListenable.removeListener(_onVipActiveChanged);
    _vipManager?.dispose();
    _vipManager = null;

    // ConsentManager singleton survives destroy() — its persisted state is
    // not tied to the adapter lifecycle, and clearing it would force a
    // re-prompt on the next initialize() which is bad UX. Caller can wipe
    // explicitly via `ConsentManager.instance.reset()`.
    _consentManager = null;

    _isSplashActive = false;
    _countInitSplashScreen = 0;
    _isFirstAdLoadTriggered = false;
    _lastBannerLoadAt = 0;
    _lastFullscreenDismissAt = 0;
    _rewardedInFlight = false;
    _isInitializing = false;
    _consentDialogScheduled = false;

    if (_isObserverAdded) {
      WidgetsBinding.instance.removeObserver(this);
      _isObserverAdded = false;
    }
    SafeLogger.d(_tag, 'destroy() ✅');
  }

  Future<void> _disposeAdapter() async {
    final old = _adapter;
    if (old != null) {
      old.appOpenSlot.state.removeListener(_onAppOpenStateChange);
      _detachFullscreenDismissWatchers();
      await old.dispose();
    }
    _adapter = null;
    _config = null;
    // Reset so the NEXT initialize() re-arms the inter+rewarded preload.
    // Without this, a re-init without explicit destroy would skip secondary
    // loads (preserves Fix V from 1.x).
    _isFirstAdLoadTriggered = false;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  CONNECTIVITY
  // ──────────────────────────────────────────────────────────────────────────

  bool get isConnected {
    try {
      return ConnectionNotifierTools.isConnected;
    } catch (_) {
      return true;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  APP OPEN
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadAppOpenAd({void Function(bool loaded)? onAdLoaded}) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — adapter null');
      onAdLoaded?.call(false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — VIP member');
      onAdLoaded?.call(false);
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — no network');
      onAdLoaded?.call(false);
      return;
    }
    // Adapter emits AdLoadEvent itself on listener fire — orchestrator only
    // forwards the boolean callback to the caller (avoids double-emit).
    await ad.loadAppOpen(onAdLoaded: onAdLoaded);
  }

  Future<void> showAppOpenAd({
    required void Function(bool dismissed) onAdDismiss,
    bool bypassSafety = false,
    AdPlacement placement = AdPlacement.splash,
  }) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — adapter null');
      onAdDismiss(false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — VIP member');
      onAdDismiss(false);
      return;
    }
    if (ad.appOpenSlot.isShowing) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — already showing');
      onAdDismiss(false);
      return;
    }
    if (!bypassSafety) {
      final s = AdSafetyConfig.canShowFullscreenAd();
      if (!s.canShow) {
        SafeLogger.d(
            _tag, () => '⏭️ showAppOpen blocked by safety: ${s.reason}');
        onAdDismiss(false);
        return;
      }
    }
    SafeLogger.d(
        _tag,
        () =>
            '▶️ showAppOpen (bypassSafety=$bypassSafety, placement=${placement.id})');
    await ad.showAppOpen(onDismiss: (dismissed) {
      if (dismissed) {
        AdSafetyConfig.recordFullscreenAdShown();
        _lastFullscreenDismissAt = DateTime.now().millisecondsSinceEpoch;
      }
      _emit(AdShowEvent(
        providerTag: ad.tag,
        type: AdSlotType.appOpen,
        placement: placement,
        success: dismissed,
      ));
      onAdDismiss(dismissed);
      unawaited(loadAppOpenAd());
    });
  }

  void showAppOpenAdOnResume() {
    final ad = _adapter;
    SafeLogger.d(
      _tag,
      () => '🔍 evaluating app-open on resume — '
          'adapter=${ad?.tag ?? "null"} '
          'splash=$_isSplashActive vip=$_isVipMember '
          'appOpenSlot=${ad?.appOpenSlot.value.name ?? "?"} '
          'interSlot=${ad?.interstitialSlot.value.name ?? "?"} '
          'rewardedSlot=${ad?.rewardedSlot.value.name ?? "?"}',
    );
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ app-open on resume skipped — adapter null');
      return;
    }
    if (_isSplashActive) {
      SafeLogger.d(_tag, '⏭️ app-open on resume skipped — splash still active');
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ app-open on resume skipped — VIP member');
      return;
    }
    if (ad.interstitialSlot.isShowing || ad.rewardedSlot.isShowing) {
      SafeLogger.d(_tag,
          '⏭️ app-open on resume skipped — interstitial/rewarded currently showing');
      return;
    }
    // Don't stack a fullscreen App Open ad on top of a modal — consent dialog,
    // VIP redeem confirmation, the SDK's own loading buffer, etc. Showing an ad
    // over a dialog is bad UX and an AdMob policy risk.
    if (AdLoadingDialog.isShowing || AdScreenRouteLogger.isDialogOnTop) {
      SafeLogger.d(
          _tag, '⏭️ app-open on resume skipped — a dialog/popup is on top');
      return;
    }

    // Guard window widened from 2 s → 5 s. Real-world fullscreen dismiss →
    // resume can stretch past 2 s on slower devices, and the slot-state
    // watcher gives us an accurate dismiss instant — so suppressing app-open
    // for 5 s after any fullscreen ad covers the bounce-back UX without
    // starving legitimate background→foreground app-open impressions.
    final dismissDelta =
        DateTime.now().millisecondsSinceEpoch - _lastFullscreenDismissAt;
    if (_lastFullscreenDismissAt > 0 && dismissDelta < 5000) {
      SafeLogger.d(
          _tag,
          () =>
              '⏭️ skipping app-open on resume (recent fullscreen dismiss ${dismissDelta}ms ago)');
      return;
    }
    final safetyResume = AdSafetyConfig.canShowAppOpenOnResume();
    if (!safetyResume.canShow) {
      SafeLogger.d(
          _tag,
          () =>
              '⏭️ app-open on resume skipped — ${safetyResume.reason} → triggering reload');
      unawaited(loadAppOpenAd());
      return;
    }
    if (!ad.appOpenSlot.isReady) {
      SafeLogger.d(
          _tag,
          () =>
              '⏭️ app-open on resume skipped — slot not ready (state=${ad.appOpenSlot.value.name}) → triggering reload');
      unawaited(loadAppOpenAd());
      return;
    }
    SafeLogger.d(
        _tag, '✅ app-open on resume — all gates passed, showing buffer + ad');

    final navContext = _navigatorKey?.currentContext;
    if (navContext != null) {
      AdLoadingDialog.showAdBuffer(navContext, onComplete: () {
        if (_isSplashActive ||
            _isVipMember ||
            ad.interstitialSlot.isShowing ||
            ad.rewardedSlot.isShowing) {
          return;
        }
        if (!ad.appOpenSlot.isReady) {
          unawaited(loadAppOpenAd());
          return;
        }
        unawaited(showAppOpenAd(
          bypassSafety: true,
          onAdDismiss: (_) => unawaited(loadAppOpenAd()),
        ));
      });
    } else {
      _resumeFallbackTimer?.cancel();
      _resumeFallbackTimer = Timer(const Duration(seconds: 1), () {
        _resumeFallbackTimer = null;
        if (!isInitialised) return;
        if (_isSplashActive ||
            _isVipMember ||
            ad.interstitialSlot.isShowing ||
            ad.rewardedSlot.isShowing) {
          return;
        }
        if (!ad.appOpenSlot.isReady) {
          unawaited(loadAppOpenAd());
          return;
        }
        unawaited(showAppOpenAd(
          bypassSafety: true,
          onAdDismiss: (_) => unawaited(loadAppOpenAd()),
        ));
      });
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  INTERSTITIAL
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadInterstitial() async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — adapter null');
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — VIP member');
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — no network');
      return;
    }
    await ad.loadInterstitial();
  }

  /// Show an interstitial. [placement] tags the call for analytics
  /// (defaults to [AdPlacement.unspecified]).
  Future<void> showInterstitial({
    required void Function(bool shown) onDoneFlow,
    AdPlacement placement = AdPlacement.unspecified,
  }) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ showInterstitial skipped — adapter null');
      onDoneFlow(false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ showInterstitial skipped — VIP member');
      onDoneFlow(false);
      return;
    }
    if (ad.interstitialSlot.isShowing) {
      SafeLogger.d(_tag, '⏭️ showInterstitial skipped — already showing');
      onDoneFlow(false);
      return;
    }
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) {
      SafeLogger.d(_tag,
          () => '⏭️ showInterstitial blocked by safety: ${safety.reason}');
      onDoneFlow(false);
      return;
    }
    SafeLogger.d(
        _tag,
        () =>
            '▶️ showInterstitial (placement=${placement.id}, slot=${ad.interstitialSlot.value.name})');
    await ad.showInterstitial(onDone: (shown) {
      if (shown) {
        AdSafetyConfig.recordFullscreenAdShown();
        _lastFullscreenDismissAt = DateTime.now().millisecondsSinceEpoch;
      }
      _emit(AdShowEvent(
        providerTag: ad.tag,
        type: AdSlotType.interstitial,
        placement: placement,
        success: shown,
      ));
      onDoneFlow(shown);
      // Fix #1 (preserved from 1.x): reload after dismiss OR show-fail to
      // keep the slot filled for the next user-triggered show. AppLovin
      // adapter ALSO reloads internally; the dedup in adapter.loadInterstitial
      // (`isReady` / `isLoading` early-return) makes the duplicate harmless.
      unawaited(loadInterstitial());
    });
  }

  bool canShowInterstitial() {
    final ad = _adapter;
    if (ad == null) return false;
    if (_isVipMember) return false;
    if (ad.interstitialSlot.isShowing) return false;
    if (AdLoadingDialog.isShowing) return false;
    final s = AdSafetyConfig.canShowFullscreenAd();
    if (!s.canShow) return false;
    return ad.interstitialSlot.isReady;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  REWARDED
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadRewardedAd() async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — adapter null');
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — VIP member');
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — no network');
      return;
    }
    await ad.loadRewarded();
  }

  /// Force-load a rewarded ad ignoring the VIP suppression and wait until it
  /// is ready (or fails / times out). Used only by the VIP-bypass branch of
  /// [showRewardedAd]; the normal flow relies on the preloaded slot.
  ///
  /// Observes the slot's **public** [AdSlot.state] notifier (not the internal
  /// `pendingCallback`, which is reserved for the app-open path) and resolves on
  /// the first `ready` (true) or `cooldown`/`idle` (false) transition.
  Future<bool> _loadRewardedOnDemand(
    AdProviderAdapter ad, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (ad.rewardedSlot.isReady) return true;
    // Adapter-level load — deliberately NOT loadRewardedAd(), which skips for
    // VIP members. `beginLoad()` flips the slot to `loading` synchronously.
    await ad.loadRewarded();
    if (ad.rewardedSlot.isReady) return true; // completed synchronously
    if (!ad.rewardedSlot.isLoading) {
      // Couldn't begin (cooldown/backoff) — no transition will come.
      return false;
    }
    final completer = Completer<bool>();
    void listener() {
      switch (ad.rewardedSlot.value) {
        case AdSlotState.ready:
          if (!completer.isCompleted) completer.complete(true);
        case AdSlotState.cooldown:
        case AdSlotState.idle:
          if (!completer.isCompleted) completer.complete(false);
        case AdSlotState.loading:
        case AdSlotState.showing:
          break; // still in flight
      }
    }

    ad.rewardedSlot.state.addListener(listener);
    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        SafeLogger.w(_tag, '⏱️ on-demand rewarded load timed out');
        return false;
      });
    } finally {
      ad.rewardedSlot.state.removeListener(listener);
    }
  }

  /// Show a rewarded ad.
  ///
  /// VIP behaviour (Q12B — caller-confirmed): the SDK does **NOT**
  /// auto-grant the reward. Caller decides via [vipAutoGrant].
  Future<void> showRewardedAd({
    required void Function(bool earned) onEarnedReward,
    bool vipAutoGrant = false,
    bool bypassVipGuard = false,
    Duration onDemandLoadTimeout = const Duration(seconds: 15),
    AdPlacement placement = AdPlacement.unspecified,
  }) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ showRewarded skipped — adapter null');
      onEarnedReward(false);
      return;
    }
    // VIP normally suppresses every ad. [bypassVipGuard] is the single,
    // explicit exception: a VIP user voluntarily watching a rewarded ad to
    // EXTEND their own VIP window (the "watch ad → +N days" flow). This is
    // policy-compliant — a real ad is still shown; we never auto-grant here.
    // Because VIP also stops the slot from being preloaded, this path
    // load-on-demands before showing.
    if (_isVipMember && !bypassVipGuard) {
      SafeLogger.d(
          _tag,
          () =>
              '⏭️ showRewarded skipped — VIP member (vipAutoGrant=$vipAutoGrant)');
      onEarnedReward(vipAutoGrant);
      return;
    }
    // Re-entrancy guard: a second call while the on-demand load OR the ad show
    // of a first call is still in flight would clobber state (two loaders, two
    // shows). Self-contained so the SDK is safe even without a caller-side lock.
    if (_rewardedInFlight || ad.rewardedSlot.isShowing) {
      SafeLogger.d(_tag, '⏭️ showRewarded skipped — already showing / in flight');
      onEarnedReward(false);
      return;
    }
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) {
      SafeLogger.d(
          _tag, () => '⏭️ showRewarded blocked by safety: ${safety.reason}');
      onEarnedReward(false);
      return;
    }
    _rewardedInFlight = true;
    // VIP bypass: the slot was never preloaded (loadRewardedAd skips for VIP),
    // so fetch one on demand and wait for it before showing. A blocking loading
    // dialog covers the wait (the slot can take seconds). A normal (non-VIP)
    // caller with a preloaded slot skips both the dialog and the wait.
    if (bypassVipGuard && !ad.rewardedSlot.isReady) {
      final ctx = _navigatorKey?.currentContext;
      if (ctx != null) AdLoadingDialog.show(ctx);
      final loaded =
          await _loadRewardedOnDemand(ad, timeout: onDemandLoadTimeout);
      AdLoadingDialog.dismiss();
      if (!loaded) {
        _rewardedInFlight = false;
        SafeLogger.d(
            _tag, '⏭️ showRewarded (bypass) — on-demand load failed');
        onEarnedReward(false);
        return;
      }
    }
    SafeLogger.d(
        _tag,
        () =>
            '▶️ showRewarded (placement=${placement.id}, vipAutoGrant=$vipAutoGrant, slot=${ad.rewardedSlot.value.name})');
    await ad.showRewarded(onDone: (result) {
      _rewardedInFlight = false;
      if (result.earned) {
        AdSafetyConfig.recordFullscreenAdShown();
        _emit(AdRewardEvent(
          providerTag: ad.tag,
          placement: placement,
          label: result.label,
          amount: result.amount,
        ));
      }
      _lastFullscreenDismissAt = DateTime.now().millisecondsSinceEpoch;
      _emit(AdShowEvent(
        providerTag: ad.tag,
        type: AdSlotType.rewarded,
        placement: placement,
        success: result.earned,
      ));
      onEarnedReward(result.earned);
      // Fix #2 (preserved from 1.x): reload after dismiss/fail. Same dedup
      // applies as for the interstitial path.
      unawaited(loadRewardedAd());
    });
  }

  /// Whether a "watch rewarded ad" entry point should be enabled.
  ///
  /// ⚠️ Returns `true` for a VIP member even though no ad will actually play —
  /// the assumption is the caller passes `vipAutoGrant: true` to
  /// [showRewardedAd] so a VIP still "earns" the reward instantly without an ad.
  /// If your caller relies on `canShowRewardedAd() == true` but calls
  /// [showRewardedAd] with the default `vipAutoGrant: false`, a VIP user will
  /// tap the button and get `earned == false` (no reward). Keep the two in sync:
  /// gate the button on `canShowRewardedAd()` AND pass `vipAutoGrant: true`.
  bool canShowRewardedAd() {
    final ad = _adapter;
    if (ad == null) return false;
    if (_isVipMember) return true;
    if (ad.rewardedSlot.isShowing) return false;
    if (AdLoadingDialog.isShowing) return false;
    final s = AdSafetyConfig.canShowFullscreenAd();
    if (!s.canShow) return false;
    return ad.rewardedSlot.isReady;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  BANNER
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadAdmobBannerIfNeeded(double widthPx) async {
    final ad = _adapter;
    if (ad == null) return;
    if (_isVipMember || !isConnected) return;
    await ad.loadBannerIfNeeded(widthPx);
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  VIP (legacy bridge — full API on AdManager().vip)
  // ──────────────────────────────────────────────────────────────────────────

  /// 1.x compat: add VIP only if THIS device's GAID matches one of the
  /// supplied gaids — preserves the per-device semantic from 1.x.
  ///
  /// Calls with non-matching GAIDs are silently ignored (in 1.x they were
  /// stored in a local list but never marked the device VIP).
  @Deprecated('Use AdManager().vip.addVip(...). Removed in 3.0.')
  void addVIPMember(List<String> gaids) {
    final v = _vipManager;
    if (v == null) return;
    final myGaid = _currentDeviceGAID.trim().toUpperCase();
    if (myGaid.isEmpty) return;
    for (final g in gaids) {
      if (g.trim().toUpperCase() != myGaid) continue;
      unawaited(v.addVip(
        key: 'LEGACY_${g.trim()}',
        duration: const Duration(days: 365 * 50),
      ));
    }
  }

  @Deprecated('Use AdManager().vip.revokeVip(...). Removed in 3.0.')
  void deleteVIPMember(List<String> gaids) {
    final v = _vipManager;
    if (v == null) return;
    final myGaid = _currentDeviceGAID.trim().toUpperCase();
    if (myGaid.isEmpty) return;
    for (final g in gaids) {
      if (g.trim().toUpperCase() != myGaid) continue;
      unawaited(v.revokeVip('LEGACY_${g.trim()}'));
    }
  }

  bool isVIPMember() => _isVipMember;

  // ──────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE OBSERVER
  // ──────────────────────────────────────────────────────────────────────────

  /// Tracks the previous lifecycle state so we can log transitions like
  /// "paused → resumed" instead of just current state.
  AppLifecycleState? _prevLifecycleState;

  /// Wall clock timestamp of last paused state — used to log how long the
  /// app was actually backgrounded on resume.
  int _lastPausedAtMs = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final prev = _prevLifecycleState;
    _prevLifecycleState = state;

    if (!isInitialised) {
      // Defensive: any field access inside the closure can throw if the
      // host activity is mid-recreation; isolate this log path so it can
      // never crash the lifecycle observer.
      _safeLifecycleLog(
        () =>
            'lifecycle: ${prev?.name ?? "—"} → ${state.name} (SDK not initialised — ignoring)',
      );
      return;
    }
    final ad = _adapter;

    // Compute background duration if resuming.
    String backgroundedFor = '';
    if (state == AppLifecycleState.resumed && _lastPausedAtMs > 0) {
      final ms = DateTime.now().millisecondsSinceEpoch - _lastPausedAtMs;
      backgroundedFor = ' | backgroundedFor=${(ms / 1000).toStringAsFixed(1)}s';
    }
    if (state == AppLifecycleState.paused) {
      _lastPausedAtMs = DateTime.now().millisecondsSinceEpoch;
    }

    // ⚠️ Critical: this lifecycle log MUST not throw. AppLovin's overlay
    // recreates the host activity on dismiss, and during that brief window
    // any GlobalKey-rooted state access (e.g. `canPop()`, navigator probes)
    // can hit a disposed-but-not-yet-cleared State and throw — which
    // bubbles up here and aborts `onAppResumed` + `showAppOpenAdOnResume`,
    // causing the next ad cycle to look "frozen".
    //
    // Keep the log to fields we own (slot ValueNotifiers, our own bools).
    // Do NOT touch _navigatorKey.currentState — that's the host's tree.
    _safeLifecycleLog(
      () => 'lifecycle: ${prev?.name ?? "—"} → ${state.name} '
          '| splash=$_isSplashActive '
          '| vip=$_isVipMember '
          '| adapter=${ad?.tag ?? "null"} '
          '| inter=${ad?.interstitialSlot.value.name ?? "?"} '
          '| rewarded=${ad?.rewardedSlot.value.name ?? "?"} '
          '| appOpen=${ad?.appOpenSlot.value.name ?? "?"} '
          '| banner=${ad?.bannerSlot.value.name ?? "?"}'
          '$backgroundedFor',
    );

    // Detached = engine is being torn down (process likely about to die).
    if (state == AppLifecycleState.detached) {
      SafeLogger.w(
          _tag,
          '🚨 lifecycle DETACHED — Flutter engine being torn down. '
          'Common causes: (a) Android killed process under memory pressure, '
          '(b) host activity destroyed while ad overlay alive, '
          '(c) launcher relaunched the app from cold. '
          'Ad slots will reset on next initialize().');
      return;
    }

    if (ad == null) return;
    if (state == AppLifecycleState.paused) {
      AdSafetyConfig.recordAppWentBackground();
      try {
        ad.onAppPaused();
      } catch (e, st) {
        SafeLogger.e(_tag, 'onAppPaused threw: $e\n$st');
      }
    } else if (state == AppLifecycleState.resumed) {
      try {
        ad.onAppResumed();
      } catch (e, st) {
        SafeLogger.e(_tag, 'onAppResumed threw: $e\n$st');
      }
      try {
        showAppOpenAdOnResume();
      } catch (e, st) {
        SafeLogger.e(_tag, 'showAppOpenAdOnResume threw: $e\n$st');
      }
    }
  }

  /// Run a lifecycle-log closure with error suppression so a missing
  /// field, disposed slot listener or any unexpected NPE inside the
  /// formatter cannot abort the lifecycle observer.
  void _safeLifecycleLog(String Function() msgBuilder) {
    try {
      SafeLogger.d(_tag, msgBuilder);
    } catch (e) {
      // Last-resort: emit something so we know the formatter died, but
      // never propagate the throw upward.
      // ignore: avoid_print
      print('roy93~ [$_tag] ⚠️ lifecycle log builder threw: $e');
    }
  }

  /// Memory pressure handler (Q32C).
  ///
  /// **Important**: we deliberately do **not** drop the native ad objects
  /// here. Doing so without coordinated `adapter.dispose()` leaks the
  /// underlying `InterstitialAd`/`RewardedAd` instances (slot state would
  /// say "idle" but the native object is still in memory, and the next
  /// `loadInterstitial()` would early-return because the cached pointer is
  /// still non-null).
  ///
  /// We log the pressure event so analytics can react — actual eviction is
  /// handled by `destroy()` if the host app decides to re-init under pressure.
  /// Memory-pressure log throttle. Background → foreground cycles fire this
  /// once per cycle; we log at most every 60 s to avoid filling the buffer
  /// when the user backgrounds the app many times in a short window.
  int _lastMemoryPressureLogAt = 0;

  @override
  void didHaveMemoryPressure() {
    final ad = _adapter;
    if (ad == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastMemoryPressureLogAt < 60000) return; // 60 s throttle
    _lastMemoryPressureLogAt = now;
    SafeLogger.w(
      _tag,
      () => '⚠️ memory pressure — '
          'inter=${ad.interstitialSlot.value.name} '
          'rewarded=${ad.rewardedSlot.value.name} '
          'appOpen=${ad.appOpenSlot.value.name} '
          'banner=${ad.bannerSlot.value.name} '
          'vip=$_isVipMember',
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  RETRY TIMER
  // ──────────────────────────────────────────────────────────────────────────

  void _startAdRetryTimer() {
    if (_retryTimerActive) return;
    _retryTimerActive = true;
    _retryGen++;
    SafeLogger.d(_tag, () => '⏲️ retry timer started (gen=$_retryGen)');
    _scheduleNextRetry(_retryGen);
  }

  void _scheduleNextRetry(int gen) {
    Future.delayed(Duration(milliseconds: _retryIntervalMs), () {
      if (gen != _retryGen || !_retryTimerActive || !isInitialised) return;
      _retryRefillAds();
      _scheduleNextRetry(gen);
    });
  }

  void _stopAdRetryTimer() {
    _retryTimerActive = false;
    _retryGen++;
  }

  void _retryRefillAds() {
    final ad = _adapter;
    if (ad == null) return;
    // VIP members never load ads. Each load*() already guards on this, but
    // bailing here keeps the periodic scan from logging/iterating pointlessly
    // and is a defense-in-depth backstop if a future load*() drops its guard.
    if (_isVipMember) return;
    SafeLogger.d(
      _tag,
      () => '⏲️ retry refill scan — vip=$_isVipMember '
          'inter=${ad.interstitialSlot.value.name} '
          'rewarded=${ad.rewardedSlot.value.name} '
          'appOpen=${ad.appOpenSlot.value.name}',
    );
    if (ad.appOpenSlot.isIdle || ad.appOpenSlot.isCooldown) {
      unawaited(loadAppOpenAd());
    }
    if (ad.interstitialSlot.isIdle || ad.interstitialSlot.isCooldown) {
      unawaited(loadInterstitial());
    }
    if (ad.rewardedSlot.isIdle || ad.rewardedSlot.isCooldown) {
      unawaited(loadRewardedAd());
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  EVENT EMIT
  // ──────────────────────────────────────────────────────────────────────────

  void _emit(AdEvent event) {
    if (_eventStream.isClosed) return;
    _eventStream.add(event);
  }
}
