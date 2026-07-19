import 'dart:async';

import 'package:advertising_id/advertising_id.dart';
import 'package:connection_notifier/connection_notifier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show ConsentStatus, DebugGeography;
import 'package:shared_preferences/shared_preferences.dart';

import '../adapters/admob_adapter.dart';
import '../adapters/applovin_adapter.dart';
import '../adaptive/adaptive_frequency.dart';
import '../compliance/ad_event_log.dart';
import '../compliance/compliance_report.dart';
import '../config/ad_config.dart';
import '../consent/consent_manager.dart';
import '../consent/consent_settings.dart';
import '../monetization/ad_diagnostics.dart';
import '../monetization/fill_rate_monitor.dart';
import '../monetization/monetization_arbitrator.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';
import '../vip/_first_install_guard.dart';
import '../vip/vip_manager.dart';
import '../widget/ad_loading_dialog.dart';
import 'ad_consent.dart';
import 'integration_self_check.dart';
import 'ad_crash_guard.dart';
import 'att_consent.dart';
import 'ad_provider_adapter.dart';
import 'ad_route_observer.dart';
import 'ad_safety_config.dart';
import 'event_bus.dart';
import 'ump_consent.dart';
import 'ump_consent.dart' as core_ump;

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
  // T42 — consent captured by setConsent()/requestUmpConsent() while
  // _consentManager is still null (i.e. before initialize() bootstraps it).
  // Without this buffer, initialize()'s bootstrap silently overwrites the
  // in-session value with stale persisted data — see setConsent() below.
  ConsentSettings? _pendingConsentSettings;

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
    // T17: a disabled first-install grace is a silent trial removal — warn
    // loudly so a partner doesn't accidentally ship with no ad-free trial.
    if (!config.firstInstallVipGrace.isEnabled) {
      warnings.add('🚨 AdConfig.firstInstallVipGrace is disabled in a '
          'RELEASE build — new installs get NO ad-free trial window. If '
          'this is intentional, ignore; otherwise set it back to '
          'FirstInstallVipGrace.auto (or .day).');
    }
    // A test-only UMP geography override left set forces EEA/test consent
    // flow for every real user in production.
    if (config.umpDebugGeography != null) {
      warnings.add('🚨 AdConfig.umpDebugGeography is set '
          '(${config.umpDebugGeography}) in a RELEASE build — this forces '
          'UMP into EEA/test mode for every real user. Remove it before '
          'shipping.');
    }
    // An empty AppLovin SDK key fails native init silently on some
    // platforms — surface it loudly at the same layer as the ad-unit-id
    // checks below.
    if (config.provider == AdProvider.appLovin &&
        (config.appLovin?.sdkKey.isEmpty ?? true)) {
      warnings.add('🚨 AppLovinConfig.sdkKey is empty in a RELEASE build — '
          'the AppLovin MAX SDK will fail to initialise natively.');
    }
    warnings.addAll(_adUnitIdFootgunWarnings(config));
    return warnings;
  }

  /// T16: empty/malformed ad-unit-id checks, split out of
  /// [releaseFootgunWarnings] purely to keep that function short — same
  /// "loud in release" contract applies (caller logs ERROR + asserts debug).
  static List<String> _adUnitIdFootgunWarnings(AdConfig config) {
    final warnings = <String>[];
    final isAdMob = config.provider == AdProvider.admob;
    // ca-app-pub-<16 digits>/<ad-unit number>, e.g. ca-app-pub-1234567890123456/1234567890.
    final admobIdPattern = RegExp(r'^ca-app-pub-\d{16}/\d+$');

    void checkId(String label, String id) {
      if (id.isEmpty) {
        warnings.add(
            '🚨 $label ad-unit id is empty in a RELEASE build — ad requests '
            'for this slot will fail with a confusing native error. Set a '
            'real production id (or remove the slot from your UI).');
        return;
      }
      if (isAdMob && !admobIdPattern.hasMatch(id)) {
        warnings.add('🚨 $label ad-unit id "$id" does not match AdMob\'s '
            'ca-app-pub-<16 digits>/<ad-unit id> format — looks like an '
            'AppLovin id (or a typo) was configured for the AdMob provider.');
      } else if (!isAdMob && admobIdPattern.hasMatch(id)) {
        warnings.add('🚨 $label ad-unit id "$id" matches AdMob\'s '
            'ca-app-pub-<16 digits>/<ad-unit id> format — looks like an '
            'AdMob id was pasted into the AppLovin config by mistake.');
      }
    }

    if (isAdMob) {
      final m = config.admob;
      if (m != null) {
        checkId('banner', m.bannerId);
        checkId('interstitial', m.interstitialId);
        checkId('appOpen', m.appOpenId);
        checkId('rewarded', m.rewardedId);
      }
    } else {
      final a = config.appLovin;
      if (a != null) {
        checkId('banner', a.bannerId);
        checkId('interstitial', a.interstitialId);
        checkId('appOpen', a.appOpenId);
        checkId('rewarded', a.rewardedId);
      }
    }
    return warnings;
  }

  /// VIP manager — `null` until [initialize] completes.
  VipManager? get vip => _vipManager;

  /// Opt-in "Smart Monetization Arbitrator" (default OFF) — `null` unless the
  /// host app calls [enableArbitrator]. When `null`, [showInterstitial] and
  /// [showRewardedAd] behave exactly as if this feature didn't exist.
  MonetizationArbitrator? _arbitrator;

  /// `null` by default — see [enableArbitrator].
  MonetizationArbitrator? get arbitrator => _arbitrator;

  /// Opt in to the Smart Monetization Arbitrator: at each fullscreen ad-show
  /// attempt (after every existing gate, including the safety layer, already
  /// passes) [arbitrator] gets one more veto — show the ad, or nudge the host
  /// app to upsell VIP instead (see [ArbitratorNudgeEvent] on [events]).
  ///
  /// Byte-for-byte no-op until this is called: [showInterstitial] and
  /// [showRewardedAd] only consult [arbitrator] when it's non-null.
  void enableArbitrator(MonetizationArbitrator arbitrator) {
    _arbitrator?.dispose();
    _arbitrator = arbitrator;
  }

  /// Test/host seam: clear a previously-registered arbitrator.
  @visibleForTesting
  void disableArbitrator() {
    _arbitrator?.dispose();
    _arbitrator = null;
  }

  /// Opt-in fill-rate monitor (default OFF) — `null` unless the host app
  /// calls [enableFillRateMonitor]. Purely observational: it never affects
  /// show/load gating, it only watches [events] and exposes trailing fill
  /// rate + a low-fill-rate alert stream.
  FillRateMonitor? _fillRateMonitor;

  /// `null` by default — see [enableFillRateMonitor].
  FillRateMonitor? get fillRateMonitor => _fillRateMonitor;

  /// Opt in to the fill-rate monitor: starts tracking trailing load success
  /// rate per [AdSlotType] from [events], and exposes [FillRateMonitor.alerts]
  /// for a low-fill-rate warning.
  void enableFillRateMonitor(FillRateMonitor monitor) {
    _fillRateMonitor?.dispose();
    _fillRateMonitor = monitor;
  }

  /// Test/host seam: clear a previously-registered fill-rate monitor.
  @visibleForTesting
  void disableFillRateMonitor() {
    _fillRateMonitor?.dispose();
    _fillRateMonitor = null;
  }

  /// One-shot snapshot combining mediation waterfall, fill rate, and
  /// arbitrator stats — see [AdDiagnostics]. [fillRateBySlot] and the
  /// arbitrator fields are empty/`null` when their subsystem was never
  /// enabled; this never enables anything itself.
  AdDiagnostics diagnostics() {
    final monitor = _fillRateMonitor;
    final arbitrator = _arbitrator;
    return AdDiagnostics(
      lastWaterfallBySlot: AdDiagnostics.lastWaterfallBySlotFrom(
          _eventLog?.entries ?? const <Map<String, dynamic>>[]),
      fillRateBySlot: monitor == null
          ? const {}
          : {for (final t in AdSlotType.values) t: monitor.fillRate(t)},
      arbitratorEstimatedEcpmMicros: arbitrator?.estimatedEcpmMicros,
      arbitratorVetoRate: arbitrator?.vetoRate,
    );
  }

  /// Debug-only integration sanity check: verifies init/consent state, then
  /// attempts an interstitial/rewarded/app-open load and waits for the
  /// resulting [AdLoadEvent] on [events]. Lets a partner confirm their
  /// [AdConfig] actually loads ads on their device without manually clicking
  /// through the example app's demo pages.
  ///
  /// Deliberately read-mostly: it never calls [destroy] and never grants or
  /// revokes a VIP entry (those mutate live session/entitlement state — too
  /// destructive as a side effect of a sanity check) — it only reports
  /// whether [vip] is wired up. Requires [initialize] to have already run;
  /// no-ops (returns a single failing item) otherwise. Always skipped
  /// outside debug builds.
  Future<SelfCheckResult> runIntegrationSelfCheck({
    Duration loadTimeout = const Duration(seconds: 15),
  }) async {
    if (!kDebugMode) {
      return const SelfCheckResult([
        SelfCheckItem('debug-mode gate', SelfCheckStatus.skipped,
            'runIntegrationSelfCheck only runs in debug builds'),
      ]);
    }
    if (!isInitialised) {
      return const SelfCheckResult([
        SelfCheckItem('SDK initialised', SelfCheckStatus.fail,
            'call AdManager().initialize(...) before running this check'),
      ]);
    }

    final consent = consentManager?.current;
    final items = <SelfCheckItem>[
      const SelfCheckItem('SDK initialised', SelfCheckStatus.pass),
      SelfCheckItem(
        'Consent flow ran',
        (consent?.hasBeenAsked ?? false)
            ? SelfCheckStatus.pass
            : SelfCheckStatus.skipped,
        (consent?.hasBeenAsked ?? false)
            ? null
            : 'consent dialog has not been shown yet this session',
      ),
      await _selfCheckLoad('Interstitial load', AdSlotType.interstitial,
          loadInterstitial, loadTimeout),
      await _selfCheckLoad(
          'Rewarded load', AdSlotType.rewarded, loadRewardedAd, loadTimeout),
      await _selfCheckLoad('App Open load', AdSlotType.appOpen,
          () => loadAppOpenAd(), loadTimeout),
      SelfCheckItem('VIP manager wired',
          vip != null ? SelfCheckStatus.pass : SelfCheckStatus.fail),
    ];
    return SelfCheckResult(items);
  }

  Future<SelfCheckItem> _selfCheckLoad(String name, AdSlotType type,
      Future<void> Function() load, Duration timeout) async {
    final completer = Completer<bool>();
    final sub = events.listen((e) {
      if (e is AdLoadEvent && e.type == type && !completer.isCompleted) {
        completer.complete(e.success);
      }
    });
    await load();
    final success =
        await completer.future.timeout(timeout, onTimeout: () => false);
    await sub.cancel();
    return SelfCheckItem(
      name,
      success ? SelfCheckStatus.pass : SelfCheckStatus.fail,
      success
          ? null
          : 'no successful AdLoadEvent for $name within '
              '${timeout.inSeconds}s',
    );
  }

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

  /// Inject a config so [isInitialised] (`_config != null && _adapter != null`)
  /// can be flipped true in tests without running the native init — used to
  /// exercise the consent → adapter (`applyConsent`) wiring.
  @visibleForTesting
  set debugConfig(AdConfig? c) => _config = c;

  /// Populated right before [initialize]'s `autoRequestUmpConsent` branch
  /// calls [requestUmpConsent] internally — lets tests assert the config's
  /// [AdConfig.umpDebugGeography]/[AdConfig.umpTestIdentifiers] are forwarded
  /// without needing native UMP to actually succeed.
  @visibleForTesting
  Map<String, Object?>? debugLastAutoUmpParams;

  /// Consent manager — `null` until [initialize] completes. Owns the
  /// Cupertino consent dialog, persistence, and provider apply pipeline.
  /// Also accessible via static [ConsentManager.instance] once initialised.
  ConsentManager? get consentManager => _consentManager;

  /// Active consent flags. Default conservative until [setConsent] is called.
  AdConsent get consent => _consent;

  /// Raw IAB TCF v2.3 consent string that Google UMP writes to native storage
  /// after a user completes the EEA consent form, or `null` if no TCF session
  /// has run yet (non-EEA users, or UMP never requested).
  Future<String?> get tcfConsentString async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('IABTCF_TCString');
  }

  /// Stream of every [AdEvent] (load / show / click / reward / revenue).
  Stream<AdEvent> get events => _eventStream.stream;
  StreamController<AdEvent> _eventStream =
      StreamController<AdEvent>.broadcast();

  /// Persisted log backing [exportComplianceReport] (T23). `null` until
  /// [initialize] completes.
  AdEventLog? _eventLog;

  /// Build a [ComplianceReport] from everything the SDK already tracks:
  /// consent state, safety-cap counters, VIP status, and the ad-event/
  /// safety-block history for `[from, to]` (open-ended if omitted).
  ///
  /// Safe to call before [initialize] or with an empty log — returns a
  /// report with zero events rather than throwing.
  ComplianceReport exportComplianceReport({DateTime? from, DateTime? to}) {
    return ComplianceReport.generate(
      events: _eventLog?.inRange(from: from, to: to) ??
          const <Map<String, dynamic>>[],
      safety: AdSafetyConfig.getStatusSnapshot(),
      consent: _consentManager?.current ?? ConsentSettings.unset,
      vipActive: _vipManager?.isActive ?? false,
      from: from,
      to: to,
    );
  }

  /// Increments on every successful [initialize]. Widgets can listen so they
  /// rebuild after a provider hot-swap or destroy → re-init cycle.
  final ValueNotifier<int> initRevision = ValueNotifier<int>(0);

  /// 0-100 real-time policy risk score (T24) blending CTR anomaly, decayed
  /// suspicious-violation history and resume spam. Dev/partner dashboard
  /// signal only — never shown to end-users, never consulted by the ad-gate
  /// logic. Safe to read pre-init (starts at 0).
  ValueListenable<int> get policyRiskScore => AdSafetyConfig.policyRiskScore;

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

  int _lastMrecLoadAt = 0;
  static const int _mrecLoadCooldownMs = 5000;

  int _lastNativeLoadAt = 0;
  static const int _nativeLoadCooldownMs = 5000;

  bool _retryTimerActive = false;
  int _retryGen = 0;

  // ─── Connectivity watch (T08) ─────────────────────────────────────────────
  StreamSubscription<bool>? _connectivitySub;
  Timer? _reconnectDebounceTimer;

  /// Last connectivity state seen by [_onConnectivityChanged]. Seeded `true`
  /// (optimistic) so the very first event only triggers a refill on a genuine
  /// offline→online transition.
  bool _lastConnected = true;

  /// True once [ConnectionNotifierTools.initialize] has resolved inside
  /// [_startConnectivityWatch]. Ad preloads triggered by [initialize] (or by
  /// a VIP state change) can run before that future settles — reading
  /// [ConnectionNotifierTools.isConnected] before then throws. Guarding on
  /// this flag avoids the exception entirely instead of catching it.
  bool _connectivityReady = false;

  final ValueNotifier<bool> _offlineNotifier = ValueNotifier<bool>(false);

  /// True while the device is offline — listenable mirror of [isConnected],
  /// same pattern as `VipManager.activeListenable`. Host UI may subscribe to
  /// render its own offline placeholder for the banner slot; the SDK itself
  /// renders nothing extra when offline (banner just hides, unchanged) — this
  /// signal is additive, not behavior-changing.
  ValueListenable<bool> get isOfflineListenable => _offlineNotifier;

  /// Debounce window collapsing connectivity flapping into a single refill.
  Duration _reconnectDebounce = const Duration(milliseconds: 800);

  /// Test seam: shorten the reconnect debounce so tests need not wait 800 ms.
  @visibleForTesting
  set debugReconnectDebounce(Duration d) => _reconnectDebounce = d;

  /// Test seam: observe the retry-timer generation counter. [_stopAdRetryTimer]
  /// unconditionally bumps this — including from the re-init guard in
  /// [initialize] that stops the previous retry timer + connectivity watch
  /// before tearing down the old adapter, so a re-init without an explicit
  /// [destroy] can't leak them.
  @visibleForTesting
  int get debugRetryGen => _retryGen;

  /// Test seam: start the periodic retry timer without going through a full
  /// [initialize] (which requires a real platform-channel adapter init).
  @visibleForTesting
  void debugStartAdRetryTimer() => _startAdRetryTimer();

  /// Test seam: stop the periodic retry timer (mirrors what [destroy] and the
  /// [initialize] re-init guard already do) without tearing down the rest of
  /// the adapter/config state.
  @visibleForTesting
  void debugStopAdRetryTimer() => _stopAdRetryTimer();

  /// Test seam: drive the connectivity handler without the native plugin.
  @visibleForTesting
  void debugConnectivityChanged(bool connected) =>
      _onConnectivityChanged(connected);

  /// Test seam: force the pre-ready gate on [isConnected] so tests can
  /// exercise its early-return branch without waiting on the real
  /// `ConnectionNotifierTools.initialize()` future.
  @visibleForTesting
  set debugConnectivityReady(bool ready) => _connectivityReady = ready;

  // ─── Consent gate (T01) ────────────────────────────────────────────────────
  /// Whether ad requests are permitted by the consent flow, mirroring Google
  /// UMP's `ConsentInformation.canRequestAds()`. Defaults `true` so non-UMP
  /// hosts and non-EEA users are unaffected; flips `false` only when UMP reports
  /// the user (EEA, form dismissed) has not granted a basis to request ads.
  /// Google policy: **never** request an ad while this is `false`.
  bool _canRequestAds = true;

  /// See [_canRequestAds].
  bool get canRequestAds => _canRequestAds;

  /// Test seam for the consent gate.
  @visibleForTesting
  set debugCanRequestAds(bool v) => _canRequestAds = v;

  /// Whether [requestUmpConsent] has ever run this process — used to detect the
  /// "no consent form anywhere" footgun at [initialize] time (AppLovin CMP off +
  /// UMP never run). Runtime state, so it doesn't false-alarm hosts that gather
  /// consent correctly in their splash.
  bool _umpRequested = false;

  /// Test seam: clear the banner load cooldown so tests sharing the singleton
  /// don't leak `_lastBannerLoadAt` into each other.
  @visibleForTesting
  void debugResetBannerCooldown() => _lastBannerLoadAt = 0;

  /// Test seam: same as [debugResetBannerCooldown] but for MREC.
  @visibleForTesting
  void debugResetMrecCooldown() => _lastMrecLoadAt = 0;

  /// Test seam: same as [debugResetBannerCooldown] but for Native.
  @visibleForTesting
  void debugResetNativeCooldown() => _lastNativeLoadAt = 0;

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
        onPrivacyPolicyTap: cfg.onPrivacyPolicyTap,
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

  // ─── MREC accessors used by MrecAdWidget ─────────────────────────────────

  bool canLoadMrec() {
    if (_lastMrecLoadAt == 0) return true;
    return DateTime.now().millisecondsSinceEpoch - _lastMrecLoadAt >=
        _mrecLoadCooldownMs;
  }

  void recordMrecLoad() {
    _lastMrecLoadAt = DateTime.now().millisecondsSinceEpoch;
  }

  ValueListenable<bool> get mrecIsLoaded =>
      _adapter?.mrec.isLoaded ?? _stubBoolFalse;

  ValueListenable<bool> get mrecHasError =>
      _adapter?.mrec.hasError ?? _stubBoolFalse;

  ValueListenable<Size?> get mrecAdSize => _adapter?.mrec.adSize ?? _stubSize;

  ValueListenable<bool> get mrecAutoRefreshEnabled =>
      _adapter?.mrec.autoRefreshEnabled ?? _stubBoolTrue;

  ValueListenable<bool> get mrecVisible =>
      _adapter?.mrec.visible ?? _stubBoolTrue;

  ValueListenable<Object?> get mrecAdViewId =>
      _adapter?.appLovinMrecAdViewId ?? _stubObject;

  String get appLovinMrecId => _adapter?.appLovinMrecId ?? '';

  bool get mrecRoutePaused => _adapter?.mrecRoutePaused ?? false;

  void setMrecRoutePaused(bool paused) => _adapter?.setMrecRoutePaused(paused);

  Widget? get admobMrecView => _adapter?.buildAdmobMrecView();

  // ─── Native accessors used by NativeAdWidget ─────────────────────────────

  bool canLoadNative() {
    if (_lastNativeLoadAt == 0) return true;
    return DateTime.now().millisecondsSinceEpoch - _lastNativeLoadAt >=
        _nativeLoadCooldownMs;
  }

  void recordNativeLoad() {
    _lastNativeLoadAt = DateTime.now().millisecondsSinceEpoch;
  }

  ValueListenable<bool> get nativeIsLoaded =>
      _adapter?.native.isLoaded ?? _stubBoolFalse;

  ValueListenable<bool> get nativeHasError =>
      _adapter?.native.hasError ?? _stubBoolFalse;

  String get appLovinNativeId => _adapter?.appLovinNativeId ?? '';

  Widget? get admobNativeView => _adapter?.buildAdmobNativeView();

  static final ValueNotifier<bool> _stubBoolFalse = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> _stubBoolTrue = ValueNotifier<bool>(true);
  static final ValueNotifier<Size?> _stubSize = ValueNotifier<Size?>(null);
  static final ValueNotifier<Object?> _stubObject =
      ValueNotifier<Object?>(null);

  // ──────────────────────────────────────────────────────────────────────────
  //  INITIALIZE — one-time async bootstrap: GAID, VIP load + migration,
  //  consent bootstrap, adapter pick + init, first App Open/banner/mrec
  //  preload, retry timer + connectivity watch. Guarded by `_isInitializing`.
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
        // Mirror destroy(): a re-init that skips these leaks the old
        // connectivity subscription/retry timer, which then double-fires
        // reconnect-triggered refills alongside the fresh adapter's own.
        _stopAdRetryTimer();
        _stopConnectivityWatch();
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

      if (config.enableCrashGuard) {
        installAdCrashGuard();
      }

      final prefs = await AdPreferences.getInstance();
      _eventLog ??= AdEventLog(prefs);
      AdaptiveFrequencySignals.setSink(
          _eventLog!.recordAdaptiveSignal); // T26: adaptive-frequency signals

      // Phase 3: pipe safety params from config.
      await AdSafetyConfig.init(prefs, params: config.safety);
      AdSafetyConfig.setAnomalySink(_emit); // T25: anomaly/fraud alert stream

      // ── Release footguns (loud, fire in release where it matters) ──────────
      for (final w in releaseFootgunWarnings(config, isDebug: kDebugMode)) {
        SafeLogger.e(_tag, w);
        assert(false, w);
      }

      // Resolve device GAID FIRST — VIP migration + first-init both need it
      // to preserve 1.x's per-device matching semantic (a `vipDeviceGaids`
      // entry only marks the device VIP when its own GAID matches).
      try {
        // ponytail: native advertising-id platform channel call, same
        // unbounded-hang risk as the adapter init below (observed hanging
        // on iOS Simulator, e.g. with ATT left notDetermined) — bound it so
        // a hang degrades to "no GAID" instead of stalling init forever.
        final id = await AdvertisingId.id(true).timeout(
          const Duration(seconds: 10),
          onTimeout: () => null,
        );
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
      _vipManager?.dispose();
      final vip =
          VipManager(prefs, maxStackDuration: config.maxVipStackDuration);
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

      // T40 — bootstrap ConsentManager (loads persisted user choice from
      // prefs) BEFORE picking/initialising the adapter, so a previously
      // recorded isAgeRestrictedUser=true can gate AppLovin's init (it has
      // no runtime child-directed API — see AppLovinAdapter.initialize).
      final consentMgr = await ConsentManager.bootstrap(
        prefs: prefs,
        strings: config.consentDialogStrings,
      );
      _consentManager = consentMgr;
      _consent = consentMgr.adConsent;

      // Pick adapter, wire its event sink, then initialise. The resolved
      // GAID is forwarded so the AppLovin adapter can register this device
      // as a test device in debug builds (preserves 1.x policy compliance).
      final adapter = config.isAdMob ? AdMobAdapter() : AppLovinAdapter();
      adapter.eventSink = _emit;
      // Same gate loadAppOpenAd()/loadInterstitial()/loadRewardedAd() consult
      // below — adapters that auto-reload from an internal dismiss/fail
      // callback (bypassing those methods entirely) must check this first.
      adapter.canReload = () =>
          !_isVipMember &&
          !AdSafetyConfig.dailyCapReached() &&
          _canRequestAds &&
          isConnected;
      // ponytail: native mediation SDK init (AppLovin/AdMob platform channel)
      // has no completion guarantee — an occasional native-side hang (seen
      // on iOS Simulator) previously wedged this await forever, permanently
      // stuck at isInitialised=false with no error surfaced. Bound it so a
      // hang degrades to a normal init-failure instead of an infinite hang.
      bool ok;
      try {
        ok = await adapter
            .initialize(
              config,
              deviceGaid: _currentDeviceGAID,
              isAgeRestrictedUser: _consent.isAgeRestrictedUser,
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        SafeLogger.e(_tag, 'adapter init TIMED OUT after 20s');
        ok = false;
      }
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

      // consentMgr was already bootstrapped above (before adapter init, so
      // T40's isAgeRestrictedUser gate could see persisted consent). If
      // config asks for auto-show AND user hasn't been asked yet, present
      // the Cupertino dialog before the first ad request. The dialog result
      // auto-applies to providers via ConsentManager.set.

      // Re-sync the adapter's per-request personalization (AdMob npa) on ANY
      // later consent change — the auto-shown consent dialog, ConsentManager
      // .set/.reset, or a host privacy screen — none of which route through
      // [setConsent]. Idempotent with the explicit applyConsent calls.
      consentMgr.listenable.addListener(_syncConsentToAdapter);

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
      // Sync per-request personalization (AdMob npa=1) into the adapter so the
      // App Open / banner preloads below carry the correct consent state.
      _adapter?.applyConsent(consentMgr.adConsent);

      // T42 — a caller (e.g. requestUmpConsent()) may have set fresh consent
      // *before* this initialize() call bootstrapped ConsentManager above,
      // in which case it was buffered into _pendingConsentSettings instead
      // of being lost. Re-apply it now so it wins over the just-loaded,
      // possibly-stale persisted data.
      final pending = _pendingConsentSettings;
      if (pending != null) {
        _pendingConsentSettings = null;
        await consentMgr.set(pending, config: config);
        _consent = consentMgr.adConsent;
        _adapter?.applyConsent(_consent);
      }

      // T01 — SDK-owned UMP: run Google's consent flow before the first ad
      // request and gate loading on canRequestAds. Opt-in; hosts that run UMP
      // in their splash leave this false to avoid double-running.
      if (config.autoRequestUmpConsent) {
        SafeLogger.d(
            _tag, '🔐 autoRequestUmpConsent — running UMP before first load');
        debugLastAutoUmpParams = {
          'testMode': kDebugMode,
          'tagForUnderAgeOfConsent': config.umpTagForUnderAgeOfConsent,
          'debugGeography': config.umpDebugGeography,
          'testIdentifiers': config.umpTestIdentifiers,
        };
        await requestUmpConsent(
          testMode: kDebugMode,
          tagForUnderAgeOfConsent: config.umpTagForUnderAgeOfConsent,
          debugGeography: config.umpDebugGeography,
          testIdentifiers: config.umpTestIdentifiers,
        );
      }

      // Consent-coverage footgun (runtime, not config-static so it doesn't
      // false-alarm hosts that gather consent in their splash): AppLovin's own
      // CMP is off, the SDK won't auto-run UMP, AND the host never called
      // requestUmpConsent() before init → EEA/UK users would see NO consent form
      // at all. Loud warning; the fix is one of: autoRequestUmpConsent:true,
      // call requestUmpConsent() before initialize(), or disableAppLovinCmpFlow:
      // false.
      if (config.disableAppLovinCmpFlow &&
          !config.autoRequestUmpConsent &&
          !_umpRequested) {
        SafeLogger.w(
            _tag,
            '🚨 No consent flow will run: AppLovin CMP is disabled, '
            'autoRequestUmpConsent is false, and requestUmpConsent() was not '
            'called before initialize(). EEA/UK users get NO consent form — '
            'GDPR/UMP policy risk. Enable autoRequestUmpConsent, call '
            'requestUmpConsent() first, or set disableAppLovinCmpFlow:false.');
      }

      onComplete(true, _currentDeviceGAID);
      SimpleEventBus().fire(const BoolEvent(true));

      SafeLogger.d(_tag, 'triggering App Open + banner preload');
      unawaited(loadAppOpenAd());
      // Banner preload also respects VIP — preloading while VIP is active
      // wastes a network request, and on AppLovin it inflates the internal
      // `recordBannerImpression` counter (the banner widget itself does
      // suppress *display*, but the cache fill is unnecessary).
      if (_isVipMember) {
        SafeLogger.d(_tag, '⏭️ banner/mrec preload skipped — VIP member');
      } else {
        unawaited(adapter.preloadBanner());
        unawaited(adapter.preloadMrec());
      }

      _scheduleFirstSecondaryLoad();
      _startAdRetryTimer();
      unawaited(_startConnectivityWatch());
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
    unawaited(ad.preloadMrec());
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
    // T14 — idempotent: if a prior initialize() already attached this
    // listener on the same adapter (re-init without an intervening
    // destroy()), drop it first so we never fire the callback twice.
    ad.appOpenSlot.state.removeListener(_onAppOpenStateChange);
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
  //  CONSENT (Phase 5) — setConsent/UMP/privacy-options/ATT: the pipeline
  //  that keeps `_canRequestAds`, both ad providers, and the persisted
  //  ConsentManager state in sync with each other.
  // ──────────────────────────────────────────────────────────────────────────

  /// Update privacy / consent flags. Forwards to both providers.
  ///
  /// Call this after running your consent UI (e.g. UMP form for AdMob).
  /// Default value before the first call is [AdConsent.conservative]
  /// (non-personalized ads everywhere).
  Future<void> setConsent(AdConsent consent) async {
    _consent = consent;
    SafeLogger.d(_tag, () => 'setConsent: $consent');
    final settings = ConsentSettings(
      hasUserConsent: consent.hasUserConsent,
      isAgeRestrictedUser: consent.isAgeRestrictedUser,
      doNotSell: consent.doNotSell,
      hasBeenAsked: true,
    );
    // T42 — _consentManager may still be null here (e.g. requestUmpConsent()
    // called before initialize() runs, which is the app's real startup
    // order). Persisting straight through it — instead of only touching the
    // in-memory _consent field — stops initialize()'s later
    // ConsentManager.bootstrap() from silently reloading stale, previously
    // persisted data and clobbering this fresh value.
    if (_consentManager != null) {
      await _consentManager!.set(settings, config: _config);
    } else {
      SafeLogger.d(_tag,
          '⏭️ setConsent: ConsentManager not bootstrapped yet — buffering for initialize()');
      _pendingConsentSettings = settings;
    }
    if (!isInitialised) {
      SafeLogger.d(_tag,
          '⏭️ setConsent: SDK not initialised — buffering for next initialize()');
      return;
    }
    await applyConsentToProviders(consent, config: _config);
    // Keep the adapter's per-request personalization (AdMob npa) in sync.
    _adapter?.applyConsent(consent);
  }

  /// Listener bound to [ConsentManager.listenable]; pushes the latest consent
  /// into the provider adapter so AdMob's per-request `npa` flag tracks every
  /// consent change (dialog answer, set/reset, privacy screen).
  void _syncConsentToAdapter() =>
      _adapter?.applyConsent(_consentManager?.adConsent ?? _consent);

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

    // T01 — the compliance gate. Google policy: do NOT request ads when
    // canRequestAds is false (EEA user who hasn't granted a basis). Every
    // load*() consults [_canRequestAds].
    _umpRequested = true;
    final wasBlocked = !_canRequestAds;
    _canRequestAds = result.canRequestAds;
    SafeLogger.d(
        _tag,
        () =>
            '🔐 UMP gate → canRequestAds=$_canRequestAds (status=${result.status.name})');

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

    // If the gate just opened (blocked → allowed) and we're already running,
    // refill the slots that were held back while consent was pending.
    if (wasBlocked && _canRequestAds && isInitialised && !_isVipMember) {
      SafeLogger.d(_tag, '🔓 consent granted → refilling held ad slots');
      _retryRefillAds();
    }
    return result;
  }

  /// Whether Google requires a durable "Privacy Options" entry point (e.g. a
  /// settings button) to be shown to the current user — true for EEA/UK
  /// users under UMP once initial consent has been gathered. Wraps
  /// [isPrivacyOptionsRequired].
  ///
  /// Host apps should check this (after [requestUmpConsent]/[initialize]) to
  /// decide whether to render a persistent "Privacy Settings" control — Google
  /// UMP policy requires a CMP to let users change their choice at any time.
  Future<bool> isPrivacyOptionsRequired() =>
      core_ump.isPrivacyOptionsRequired();

  /// Open Google's native UMP "Privacy Options" form, letting the user
  /// revisit/change their consent choice at any time. Wraps
  /// [requestPrivacyOptionsFlow] — see its doc for details.
  ///
  /// Typical usage: bind to a host "Privacy Settings" button, shown
  /// persistently once [isPrivacyOptionsRequired] returns true.
  /// ```dart
  /// if (await AdManager().isPrivacyOptionsRequired()) {
  ///   // render the settings button
  /// }
  /// // on tap:
  /// await AdManager().showPrivacyOptions();
  /// ```
  ///
  /// No-op-safe: if Google doesn't require privacy options for this user
  /// (non-EEA, or consent never gathered), this returns immediately without
  /// presenting anything. On success, the result is re-mapped to [AdConsent]
  /// and re-applied to both providers via [setConsent] — matching the
  /// established "re-apply after consent change" pattern used by
  /// [ConsentManager] and [requestUmpConsent].
  Future<PrivacyOptionsResult> showPrivacyOptions() async {
    final result = await requestPrivacyOptionsFlow();

    final wasBlocked = !_canRequestAds;
    _canRequestAds = result.canRequestAds;
    SafeLogger.d(
        _tag,
        () =>
            '🔐 privacy options → canRequestAds=$_canRequestAds (status=${result.status.name})');

    final hasConsent = result.status == ConsentStatus.obtained ||
        result.status == ConsentStatus.notRequired;
    await setConsent(AdConsent(
      hasUserConsent: hasConsent,
      isAgeRestrictedUser: _consent.isAgeRestrictedUser,
      doNotSell: _consent.doNotSell,
    ));

    if (wasBlocked && _canRequestAds && isInitialised && !_isVipMember) {
      SafeLogger.d(_tag,
          '🔓 consent granted via privacy options → refilling held ad slots');
      _retryRefillAds();
    }
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
  //  DESTROY — full teardown: disposes the adapter, VIP/arbitrator/fill-rate
  //  managers, timers and the lifecycle observer, then resets in-memory
  //  flags so a later initialize() starts clean.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> destroy() async {
    SafeLogger.d(_tag, 'destroy() called');
    await _eventStream.close();
    _eventStream = StreamController<AdEvent>.broadcast();
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
    _stopConnectivityWatch();
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
    _consentManager?.listenable.removeListener(_syncConsentToAdapter);
    _consentManager = null;
    // A setConsent() call buffered before the (now torn-down) init never got
    // applied — dropping it here (rather than carrying it into a future
    // initialize()) matches destroy() being an explicit, deliberate teardown.
    _pendingConsentSettings = null;

    // Same reasoning as VipManager above: a stale arbitrator/fill-rate-monitor
    // left alive past destroy() would keep being consulted (or keep counting
    // fill-rate samples) against a torn-down adapter, mixing pre-destroy data
    // into whatever provider initialize() brings up next.
    _arbitrator?.dispose();
    _arbitrator = null;
    _fillRateMonitor?.dispose();
    _fillRateMonitor = null;

    _isSplashActive = false;
    _countInitSplashScreen = 0;
    _isFirstAdLoadTriggered = false;
    _lastBannerLoadAt = 0;
    _lastFullscreenDismissAt = 0;
    _rewardedInFlight = false;
    _isInitializing = false;
    _consentDialogScheduled = false;
    _offlineNotifier.value = false;

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
  //  CONNECTIVITY — `isConnected` getter only; falls back to the last value
  //  the CONNECTIVITY WATCH (T08, below) observed if the detector isn't
  //  ready yet or throws.
  // ──────────────────────────────────────────────────────────────────────────

  bool get isConnected {
    if (!_connectivityReady) {
      // ConnectionNotifierTools.initialize() (in _startConnectivityWatch)
      // hasn't resolved yet — reading it now would throw. Ad preloads
      // fired from initialize()/VIP-change callbacks can race this.
      SafeLogger.d(
          _tag,
          () =>
              'isConnected read before ready, using last-known=$_lastConnected');
      return _lastConnected;
    }
    try {
      return ConnectionNotifierTools.isConnected;
    } catch (e) {
      // Detector not initialised / unavailable — fall back to the last value the
      // connectivity watch (T08) observed, seeded optimistic `true`. Optimistic
      // on purpose: a broken detector must NOT permanently block ads when the
      // device may well be online — a genuinely offline load just fails and
      // backs off, and the connectivity watch refills on reconnect.
      SafeLogger.w(
          _tag,
          () =>
              'isConnected read failed, using last-known=$_lastConnected: $e');
      return _lastConnected;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  APP OPEN — load/show/showOnResume, each gated by its own chain of
  //  VIP/daily-cap/consent/connectivity/dialog-on-top checks before ever
  //  touching the adapter.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadAppOpenAd({void Function(bool loaded)? onAdLoaded}) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — adapter null');
      onAdLoaded?.call(false);
      return;
    }
    if (_config?.appOpenTrigger == AppOpenTrigger.splashOnly &&
        !_isSplashActive) {
      // splashOnly never shows via showAppOpenAdOnResume() (gated there), so
      // any load after splash ends would never be shown — skip to avoid
      // wasting quota/network on an ad that can't be used.
      SafeLogger.d(_tag,
          '⏭️ loadAppOpen skipped — appOpenTrigger=splashOnly, splash inactive');
      onAdLoaded?.call(false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — VIP member');
      onAdLoaded?.call(false);
      return;
    }
    if (AdSafetyConfig.dailyCapReached()) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — daily cap reached');
      onAdLoaded?.call(false);
      return;
    }
    if (!_canRequestAds) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — consent not granted (UMP)');
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
    if (bypassSafety && _config?.appOpenTrigger == AppOpenTrigger.resumeOnly) {
      SafeLogger.d(
          _tag, '⏭️ showAppOpen (splash) skipped — appOpenTrigger=resumeOnly');
      onAdDismiss(false);
      return;
    }
    // T03 — never show an impression before consent is resolved, even the
    // splash App Open with bypassSafety. The load gate already prevents loading,
    // this closes the window where a previously-loaded ad could show after
    // consent is revoked.
    if (!_canRequestAds) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — consent not granted (UMP)');
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
    if (_config?.appOpenTrigger == AppOpenTrigger.splashOnly) {
      SafeLogger.d(
          _tag, '⏭️ app-open on resume skipped — appOpenTrigger=splashOnly');
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
  //  INTERSTITIAL — load/show/canShow, mirroring the App Open gates (VIP,
  //  consent, safety) plus the optional arbitrator nudge-to-VIP veto.
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
    if (AdSafetyConfig.dailyCapReached()) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — daily cap reached');
      return;
    }
    if (!_canRequestAds) {
      SafeLogger.d(
          _tag, '⏭️ loadInterstitial skipped — consent not granted (UMP)');
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
    if (!_canRequestAds) {
      SafeLogger.d(
          _tag, '⏭️ showInterstitial skipped — consent not granted (UMP)');
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
    // Opt-in Smart Monetization Arbitrator (default OFF — see
    // enableArbitrator). Only consulted when a host app has registered one.
    final arbitrator = _arbitrator;
    if (arbitrator != null &&
        arbitrator.decide(AdSlotType.interstitial) ==
            ArbitratorDecision.nudgeVip) {
      SafeLogger.d(_tag, '⏭️ showInterstitial vetoed — arbitrator nudgeVip');
      _emit(ArbitratorNudgeEvent(
        type: AdSlotType.interstitial,
        placement: placement,
        estimatedEcpmMicros: arbitrator.estimatedEcpmMicros,
      ));
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
  //  REWARDED — load/show/canShow, plus the on-demand load path used when a
  //  VIP member watches an ad to extend their own VIP window
  //  (`bypassVipGuard`).
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
    if (AdSafetyConfig.dailyCapReached()) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — daily cap reached');
      return;
    }
    if (!_canRequestAds) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — consent not granted (UMP)');
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
  ///
  /// ⚠️ [bypassVipGuard] is **not** a policy bypass — read it as "skip the
  /// VIP-suppression *guard*", not "skip ad policy". A **real** rewarded ad
  /// is still requested, throttled by [AdSafetyConfig.canShowFullscreenAd],
  /// and counted like any other impression; every other safety gate in this
  /// method (consent, re-entrancy, cooldowns) still applies unchanged. Its
  /// one and only purpose is the single existing "VIP watches an ad to
  /// extend their own VIP window" flow (see [VipManager] `stack: true`
  /// grants), where the normal VIP-suppression branch above would otherwise
  /// prevent the ad from ever loading. Pass `true` only from that flow.
  ///
  /// [ssvCustomData]/[ssvUserId] are optional Server-Side Verification (SSV)
  /// identifiers, forwarded verbatim to the native SDK's real SSV field
  /// (AppLovin: `custom_data`; AdMob: `ServerSideVerificationOptions`). This
  /// SDK does NOT run a server and does NOT verify anything itself — it only
  /// plumbs the data through so the PARTNER's OWN backend can match it
  /// against AppLovin's/AdMob's reward postback. See README "Server-Side
  /// Verification". Omitting both preserves today's fully client-side
  /// behavior exactly; supplying either sets
  /// `RewardResult.pendingServerConfirmation` (surfaced here only as
  /// `onEarnedReward`'s `earned` flag — read `AdManager().events` /
  /// `AdRewardEvent` if you need the pending flag itself).
  Future<void> showRewardedAd({
    required void Function(bool earned) onEarnedReward,
    bool vipAutoGrant = false,
    bool bypassVipGuard = false,
    Duration onDemandLoadTimeout = const Duration(seconds: 15),
    AdPlacement placement = AdPlacement.unspecified,
    String? ssvCustomData,
    String? ssvUserId,
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
    // T03 — no impression without consent. (The vipAutoGrant-no-ad path above
    // already returned; this only gates paths that would actually show an ad.)
    if (!_canRequestAds) {
      SafeLogger.d(_tag, '⏭️ showRewarded skipped — consent not granted (UMP)');
      onEarnedReward(false);
      return;
    }
    // Re-entrancy guard: a second call while the on-demand load OR the ad show
    // of a first call is still in flight would clobber state (two loaders, two
    // shows). Self-contained so the SDK is safe even without a caller-side lock.
    if (_rewardedInFlight || ad.rewardedSlot.isShowing) {
      SafeLogger.d(
          _tag, '⏭️ showRewarded skipped — already showing / in flight');
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
    // Opt-in Smart Monetization Arbitrator (default OFF — see
    // enableArbitrator). Only consulted when a host app has registered one.
    // Deliberately NOT applied to the VIP watch-ad-to-extend-VIP bypass path
    // (bypassVipGuard) — that flow is the user already spending their own
    // time to earn more VIP, vetoing it would defeat its purpose. It's also
    // skipped for the same reason a low-eCPM veto shouldn't block a user who
    // is already mid-VIP-purchase-flow.
    final arbitrator = _arbitrator;
    if (!bypassVipGuard &&
        arbitrator != null &&
        arbitrator.decide(AdSlotType.rewarded) == ArbitratorDecision.nudgeVip) {
      SafeLogger.d(_tag, '⏭️ showRewarded vetoed — arbitrator nudgeVip');
      _emit(ArbitratorNudgeEvent(
        type: AdSlotType.rewarded,
        placement: placement,
        estimatedEcpmMicros: arbitrator.estimatedEcpmMicros,
      ));
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
        SafeLogger.d(_tag, '⏭️ showRewarded (bypass) — on-demand load failed');
        onEarnedReward(false);
        return;
      }
    }
    SafeLogger.d(
        _tag,
        () =>
            '▶️ showRewarded (placement=${placement.id}, vipAutoGrant=$vipAutoGrant, slot=${ad.rewardedSlot.value.name})');
    await ad.showRewarded(
        ssvCustomData: ssvCustomData,
        ssvUserId: ssvUserId,
        onDone: (result) {
          _rewardedInFlight = false;
          if (result.earned) {
            AdSafetyConfig.recordFullscreenAdShown();
            _emit(AdRewardEvent(
              providerTag: ad.tag,
              placement: placement,
              label: result.label,
              amount: result.amount,
              pendingServerConfirmation: result.pendingServerConfirmation,
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
  //  BANNER — single load-if-needed entry point; state/cooldown/accessors
  //  live in the "Banner accessors" section near the top of the class.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadAdmobBannerIfNeeded(double widthPx) async {
    final ad = _adapter;
    if (ad == null) return;
    if (_isVipMember || !isConnected) return;
    await ad.loadBannerIfNeeded(widthPx);
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  MREC — load-if-needed for MREC + native; state/accessors live in the
  //  "MREC/Native accessors" sections near the top of the class.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadAdmobMrecIfNeeded(double widthPx) async {
    final ad = _adapter;
    if (ad == null) return;
    if (_isVipMember || !isConnected) return;
    await ad.loadMrecIfNeeded(widthPx);
  }

  Future<void> loadAdmobNativeIfNeeded() async {
    final ad = _adapter;
    if (ad == null) return;
    if (_isVipMember || !isConnected) return;
    await ad.preloadNative();
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
  //  LIFECYCLE OBSERVER — WidgetsBindingObserver callbacks: pause/resume
  //  forwarding to the adapter, resume-triggered App Open, and throttled
  //  memory-pressure logging.
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
  //  RETRY TIMER — self-rescheduling poll (every `_retryIntervalMs`) calling
  //  `_retryRefillAds()`; the steady-state backstop behind the
  //  faster CONNECTIVITY WATCH (T08, below) reconnect path.
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

  // ──────────────────────────────────────────────────────────────────────────
  //  CONNECTIVITY WATCH (T08) — auto-refill the moment the network returns
  //  instead of waiting up to `_retryIntervalMs` (5 min) for the poll timer.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _startConnectivityWatch() async {
    // ConnectionNotifierTools must be initialised before its stream/isConnected
    // are usable. Nobody else calls this, so the SDK owns it. Best-effort: on
    // platforms/tests without the plugin we simply skip the live watch.
    try {
      await ConnectionNotifierTools.initialize();
      _connectivityReady = true;
      _lastConnected = ConnectionNotifierTools.isConnected;
      _offlineNotifier.value = !_lastConnected;
      _connectivitySub =
          ConnectionNotifierTools.onStatusChange.listen(_onConnectivityChanged);
      SafeLogger.d(_tag,
          () => '📶 connectivity watch started (connected=$_lastConnected)');
    } catch (e) {
      SafeLogger.w(_tag, 'connectivity watch unavailable: $e');
    }
  }

  void _stopConnectivityWatch() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _reconnectDebounceTimer?.cancel();
    _reconnectDebounceTimer = null;
  }

  /// Handles a connectivity event. Only an offline→online transition triggers a
  /// refill, debounced against flapping. Idempotent and safe post-destroy.
  void _onConnectivityChanged(bool connected) {
    final was = _lastConnected;
    _lastConnected = connected;
    _offlineNotifier.value = !connected;
    if (!connected || was) return; // only act on false→true
    _reconnectDebounceTimer?.cancel();
    _reconnectDebounceTimer = Timer(_reconnectDebounce, () {
      if (!isInitialised || _isVipMember) return;
      SafeLogger.d(
          _tag, '📶 network back online → refilling ad slots + banners');
      _retryRefillAds();
      // Banners re-run their init on an initRevision bump (the widget checks
      // isConnected in _initBanner); also nudge the adapter's banner preload.
      unawaited(_adapter?.preloadBanner() ?? Future<void>.value());
      initRevision.value = initRevision.value + 1;
    });
  }

  void _retryRefillAds() {
    final ad = _adapter;
    if (ad == null) return;
    // VIP members never load ads. Each load*() already guards on this, but
    // bailing here keeps the periodic scan from logging/iterating pointlessly
    // and is a defense-in-depth backstop if a future load*() drops its guard.
    if (_isVipMember) return;
    // Same defense-in-depth rationale as the VIP guard above: each load*()
    // already checks the daily cap, but bailing here stops the periodic
    // scan from even scheduling the unawaited loads once capped.
    if (AdSafetyConfig.dailyCapReached()) return;
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
  //  EVENT EMIT — single `_emit()` chokepoint: records to the compliance
  //  event log, then broadcasts on the public `events` stream.
  // ──────────────────────────────────────────────────────────────────────────

  void _emit(AdEvent event) {
    _eventLog?.recordEvent(event,
        consentCountry: _consentManager?.current.country);
    if (_eventStream.isClosed) return;
    _eventStream.add(event);
  }
}
