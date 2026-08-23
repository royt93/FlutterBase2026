import 'dart:async';
import 'dart:io' show Platform;

import 'package:advertising_id/advertising_id.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:connection_notifier/connection_notifier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show ConsentStatus, DebugGeography, TemplateType;

import '../adapters/admob_adapter.dart';
import '../adapters/applovin_adapter.dart';
import '../adaptive/adaptive_frequency.dart';
import '../compliance/ad_event_log.dart';
import '../compliance/compliance_report.dart';
import '../compliance/compliance_signing.dart';
import '../config/ad_config.dart';
import '../config/remote_ad_safety_provider.dart';
import '../consent/consent_manager.dart';
import '../consent/consent_settings.dart';
import '../monetization/ad_diagnostics.dart';
import '../monetization/fill_rate_baseline_monitor.dart';
import '../monetization/fill_rate_monitor.dart';
import '../monetization/monetization_arbitrator.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/ad_preferences.dart';
import '../utils/experiment_bucket.dart' as experiment;
import '../utils/release_mode.dart';
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
import 'iab_storage.dart';
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
    // T75 — these two live for the whole process (unlike the adapter, which
    // is re-wired by the `_adapter` setter above on every init/destroy), so
    // wiring them once here is enough.
    umpFormOnScreen.addListener(_recomputeFullscreenBusy);
    AdLoadingDialog.isShowingNotifier.addListener(_recomputeFullscreenBusy);
    AdScreenRouteLogger.isDialogOnTopNotifier
        .addListener(_recomputeFullscreenBusy);
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
  AdProviderAdapter? _adapterField;

  /// T75 — every assignment (real init, `destroy()`'s reset, and the
  /// `debugSetAdapter` test seam) funnels through this setter so
  /// [fullscreenBusy]'s slot listeners always stay attached to whichever
  /// adapter is actually live, without touching any of those call sites.
  AdProviderAdapter? get _adapter => _adapterField;
  set _adapter(AdProviderAdapter? value) {
    _detachFullscreenBusySlotListeners();
    _adapterField = value;
    _attachFullscreenBusySlotListeners();
    _recomputeFullscreenBusy();
  }

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
  ///
  /// Does NOT check `dryRun`: that guard now lives solely in
  /// `AdSafetyConfig.init()` (R12-A), which `initialize()` always calls right
  /// before this. Calling this method standalone — without having run
  /// `AdSafetyConfig.init()` first — will NOT warn about a release build with
  /// `dryRun: true`; it only covers the checks below (Google test ad unit IDs).
  @visibleForTesting
  static List<String> releaseFootgunWarnings(AdConfig config,
      {required bool isDebug}) {
    if (isDebug) return const [];
    final warnings = <String>[];
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

  /// F4 — AppLovin's own CMP is off, the SDK won't auto-run UMP, AND the
  /// host never called [requestUmpConsent] before `initialize()` → EEA/UK
  /// users would see NO consent form at all. Returns a warning message when
  /// this footgun is hit, or `null` when consent coverage is fine. Pure +
  /// static so it is unit-testable without running the full native init —
  /// same pattern as [releaseFootgunWarnings].
  /// BL2 (round 5 audit) — `disableAppLovinCmpFlow` is read in exactly one
  /// place in this package (`AppLovinAdapter.initialize`), so on AdMob it
  /// means nothing at all. Testing `!config.disableAppLovinCmpFlow`
  /// unconditionally therefore let a legal config — `provider: admob`,
  /// `autoRequestUmpConsent: false`, `disableAppLovinCmpFlow: false` — return
  /// `null` here, which skips the guard entirely and leaves `_canRequestAds`
  /// at its default `true`: EEA/UK users served ads with no consent flow of
  /// any kind, and no warning either. Fail-open in the exact branch this
  /// guard exists to close. Now only counts AppLovin's CMP as consent
  /// coverage when AppLovin is actually the active provider.
  @visibleForTesting
  static String? consentFootgunWarning(AdConfig config,
      {required bool umpRequested, bool consentExplicitlySet = false}) {
    final appLovinCmpCovers = config.provider == AdProvider.appLovin &&
        !config.disableAppLovinCmpFlow;
    if (appLovinCmpCovers ||
        config.autoRequestUmpConsent ||
        umpRequested ||
        consentExplicitlySet) {
      return null;
    }
    return '🚨 No consent flow will run: autoRequestUmpConsent is false, '
        'requestUmpConsent() was not called before initialize(), and no CMP '
        'covers this provider (${config.provider.name}). EEA/UK users get NO '
        'consent form — GDPR/UMP policy risk. Enable autoRequestUmpConsent, '
        'or call requestUmpConsent() before initialize().';
  }

  /// F9 hardened (2026-08-19 audit, Finding 7) — [requestUmpConsent] already
  /// logs a `SafeLogger.w` the moment it runs before [requestAtt] on iOS,
  /// but that log is easy to miss and fires the same in every build. This
  /// surfaces the same condition as a release-build footgun (same "loud in
  /// release" contract as [releaseFootgunWarnings]/[consentFootgunWarning])
  /// so a host that never calls `requestAtt()` at all gets a harder-to-miss
  /// signal. Does not block ad requests — unlike a missing consent flow,
  /// this is a revenue/attribution risk (native SDKs already gate IDFA use
  /// on ATT status themselves), not a legal-compliance block. Pure + static
  /// so it is unit-testable without running the full native init.
  @visibleForTesting
  static String? attOrderFootgunWarning(
      {required bool attRequested, required bool isIos}) {
    if (!isIos || attRequested) return null;
    return '🚨 requestAtt() was never called before initialize() completed '
        'on iOS — IDFA availability is unsettled for the first ad '
        'request(s), losing attribution/revenue. Call '
        'AdManager().requestAtt() in your splash screen before '
        'initialize()/requestUmpConsent().';
  }

  /// M9 (audit_claude.md, 2026-08-20) — [initialize]'s GAID fetch used to
  /// call `AdvertisingId.id(true)` unconditionally, but on iOS that plugin
  /// triggers its own ATT prompt as a side effect whenever status isn't
  /// `.authorized` — a second, hidden ATT trigger independent of whether the
  /// host called [requestAtt] first. Deferring is only safe/necessary when
  /// ATT is still undecided AND the host hasn't already called [requestAtt]
  /// (which means the real trigger has already fired, or never will on this
  /// platform). Pure + static so it is unit-testable without a native ATT
  /// status read.
  @visibleForTesting
  static bool shouldDeferGaidFetch(
      {required bool isIos,
      required bool attRequested,
      required TrackingStatus? attStatus}) {
    if (!isIos) return false;
    // m7 (round 5 audit) — `attStatus == null` means the ATT status read
    // itself threw, i.e. we do NOT know whether the user has been asked. That
    // used to fall through to `false`, which sent initialize() straight into
    // `AdvertisingId.id(true)` — the `true` asks the plugin to trigger the ATT
    // prompt — so a failed status read could pop Apple's tracking dialog from
    // inside initialize(), out of the host's control and possibly before its
    // UI is ready. Unknown has to be treated like notDetermined: defer.
    //
    // Same for `attRequested == true` with a status still notDetermined: the
    // ATT call timed out (att_consent.dart's own guard) so the user has not
    // actually answered, and asking again is not ours to do here.
    if (attStatus == TrackingStatus.notDetermined) return true;
    if (attRequested) return false;
    return attStatus == null;
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

  /// T72 — fires exactly once `false → true` when [vip] transitions from
  /// `null` to ready, so a screen that renders before SDK init completes
  /// has a clear DX for "wait for VIP state" instead of polling
  /// [initRevision] and re-checking `vip != null` itself. Reset to `false`
  /// by [destroy] (mirrors [vip] itself going back to `null` there).
  final ValueNotifier<bool> _vipReadyNotifier = ValueNotifier<bool>(false);
  ValueListenable<bool> get vipReady => _vipReadyNotifier;

  /// T93 — deterministic A/B bucket assignment for [key], in `[0, buckets)`.
  /// Same result every call for the same `(key, buckets)` on this install —
  /// lets a host A/B test `AdSafetyParams`/arbitrator thresholds without
  /// integrating a remote-config backend (lighter than [RemoteAdSafetyProvider]
  /// (T88) — purely local, no network).
  ///
  /// Prefers the real GAID when available (stable, no extra storage); falls
  /// back to a lazily-generated pseudonymous install id persisted via
  /// [AdPreferences] when GAID is empty/all-zeros (Limit Ad Tracking / no ATT
  /// permission) — otherwise every opted-out user would collide into bucket
  /// 0 of every experiment, biasing results for a potentially large fraction
  /// of the audience.
  ///
  /// ```dart
  /// final bucket = AdManager().experimentBucket('daily_cap_experiment', buckets: 2);
  /// final safety = bucket == 0
  ///     ? AdSafetyParams.production
  ///     : AdSafetyParams.production.copyWith(maxFullscreenAdsPerDay: 8);
  /// ```
  int experimentBucket(String key, {required int buckets}) {
    final gaid = _currentDeviceGAID.trim();
    final installId = (gaid.isNotEmpty && gaid.toLowerCase() != _zeroGaid)
        ? gaid
        : (AdPreferences.instanceOrNull?.getOrCreateExperimentInstallId() ??
            gaid);
    return experiment.experimentBucket(installId, key, buckets: buckets);
  }

  /// T90 — deterministic 50/50 provider A/B split, built on
  /// [experimentBucket]. Call this BEFORE building [AdConfig] (provider is
  /// fixed for the whole session once [initialize] runs) — the returned
  /// value IS the `provider:` to construct it with:
  ///
  /// ```dart
  /// final provider = AdManager().pickProviderCohort();
  /// await AdManager().initialize(
  ///   config: AdConfig(provider: provider, admob: ..., appLovin: ...),
  ///   onComplete: (success, gaid) { /* ... */ },
  /// );
  /// ```
  ///
  /// Comparing eCPM/fill-rate between the two cohorts needs no new plumbing
  /// here — every event on `AdManager().events` (see [AdEvent]'s doc comment
  /// for the "pipe into your own analytics" pattern) already carries
  /// `providerTag` (`'[AdMob]'`/`'[AppLovin]'`), so a host's own analytics
  /// pipeline can group `AdLoadEvent.success`/`AdRevenueEvent.valueMicros` by
  /// that field across its install base.
  AdProvider pickProviderCohort({String key = 'provider_ab_test'}) =>
      experimentBucket(key, buckets: 2) == 0
          ? AdProvider.admob
          : AdProvider.appLovin;

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

  /// Opt-in 7-day fill-rate/eCPM baseline regression detector (T97, default
  /// OFF) — `null` unless [enableFillRateBaselineMonitor] was called.
  /// Compares this session against this device's own persisted trailing
  /// 7-day history; see [FillRateBaselineMonitor]'s doc comment.
  FillRateBaselineMonitor? _fillRateBaselineMonitor;

  /// `null` by default — see [enableFillRateBaselineMonitor].
  FillRateBaselineMonitor? get fillRateBaselineMonitor =>
      _fillRateBaselineMonitor;

  /// Guards the race below — bumped by every [enableFillRateBaselineMonitor]
  /// / [disableFillRateBaselineMonitor] call so a call that started earlier
  /// can detect a later one already won and dispose its own (otherwise
  /// orphaned) instance instead of overwriting the field.
  int _fillRateBaselineMonitorGen = 0;

  /// Opt in to the fill-rate/eCPM baseline regression detector. Needs
  /// `AdPreferences` (internal, hence `async` rather than host-constructed
  /// like [enableFillRateMonitor]) — safe to call any time after
  /// `initialize()`.
  ///
  /// Safe to call twice back-to-back without awaiting the first call: the
  /// `await AdPreferences.getInstance()` below is a real suspension point,
  /// so two overlapping calls could otherwise both read the OLD
  /// `_fillRateBaselineMonitor` before either writes the new one — the
  /// loser's instance would replace the field without ever disposing the
  /// winner's, leaking its `AdManager().events` subscription forever. The
  /// generation token below makes whichever call's `await` resolves LAST
  /// win, and makes the other dispose its own (now-orphaned) instance
  /// instead.
  Future<void> enableFillRateBaselineMonitor({
    double regressionThreshold = 0.2,
    int minSamples = 5,
  }) async {
    final myGen = ++_fillRateBaselineMonitorGen;
    final prefs = await AdPreferences.getInstance();
    final monitor = FillRateBaselineMonitor(
      prefs,
      regressionThreshold: regressionThreshold,
      minSamples: minSamples,
    );
    if (myGen != _fillRateBaselineMonitorGen) {
      // A later call (or disableFillRateBaselineMonitor) already won while
      // we were awaiting — don't clobber it, and don't leak this instance.
      monitor.dispose();
      return;
    }
    _fillRateBaselineMonitor?.dispose();
    _fillRateBaselineMonitor = monitor;
  }

  /// Test/host seam: clear a previously-enabled baseline monitor.
  @visibleForTesting
  void disableFillRateBaselineMonitor() {
    _fillRateBaselineMonitorGen++;
    _fillRateBaselineMonitor?.dispose();
    _fillRateBaselineMonitor = null;
  }

  /// One-shot snapshot combining mediation waterfall, fill rate, and
  /// arbitrator stats — see [AdDiagnostics]. [fillRateBySlot] and the
  /// arbitrator fields are empty/`null` when their subsystem was never
  /// enabled; this never enables anything itself.
  AdDiagnostics diagnostics() {
    final monitor = _fillRateMonitor;
    final arbitrator = _arbitrator;
    final baselineMonitor = _fillRateBaselineMonitor;
    return AdDiagnostics(
      lastWaterfallBySlot: AdDiagnostics.lastWaterfallBySlotFrom(
          _eventLog?.entries ?? const <Map<String, dynamic>>[]),
      fillRateBySlot: monitor == null
          ? const {}
          : {for (final t in AdSlotType.values) t: monitor.fillRate(t)},
      arbitratorEstimatedEcpmMicros: arbitrator?.estimatedEcpmMicros,
      arbitratorVetoRate: arbitrator?.vetoRate,
      fillRateRegressionBySlot: baselineMonitor?.activeAlerts ?? const {},
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
      _selfCheckNavigatorKey(),
      _selfCheckRouteObserver(),
      await _selfCheckAtt(),
    ];
    return SelfCheckResult(items);
  }

  /// T98 — the integration contract requires `setNavigatorKey` before
  /// `runApp` (see README's "Integrate the SDK"). `skipped` (not `fail`)
  /// when the key is set but not yet attached to a live tree — this method
  /// runs from a widget's `initState`/build, so "not attached yet" can just
  /// mean the check ran before the first frame, not a real misconfiguration.
  SelfCheckItem _selfCheckNavigatorKey() {
    final key = _navigatorKey;
    if (key == null) {
      return const SelfCheckItem(
          'Navigator key wired',
          SelfCheckStatus.fail,
          'call AdManager().setNavigatorKey(navigatorKey) before runApp — '
              'see README "Integrate the SDK"');
    }
    if (key.currentContext == null) {
      return const SelfCheckItem(
          'Navigator key wired',
          SelfCheckStatus.skipped,
          'navigatorKey is set but not yet attached to a live Navigator — '
              're-run this check after the first frame');
    }
    return const SelfCheckItem('Navigator key wired', SelfCheckStatus.pass);
  }

  /// T98 — `AdScreenRouteLogger` must be in `navigatorObservers` for RouteAware
  /// banner lifecycle + the App-Open-never-stacks-on-a-dialog guard to work.
  /// `AdScreenRouteLogger.navigationEventsObserved` only ever increments if an
  /// instance is actually receiving callbacks from a real `Navigator`, so a
  /// non-zero count is real evidence of correct wiring — `skipped` (not
  /// `fail`) at zero, since this may just mean no route has pushed yet.
  SelfCheckItem _selfCheckRouteObserver() {
    if (AdScreenRouteLogger.navigationEventsObserved > 0) {
      return const SelfCheckItem('Route observer wired', SelfCheckStatus.pass);
    }
    return const SelfCheckItem(
        'Route observer wired',
        SelfCheckStatus.skipped,
        'no navigation events observed yet — add AdScreenRouteLogger() to '
            'navigatorObservers, or re-run this check after a route has pushed');
  }

  /// T98 — read-only (never prompts) sanity check that the
  /// `app_tracking_transparency` native plugin responds at all, catching a
  /// broken iOS embed early. Deliberately does NOT call
  /// `requestTrackingAuthorization()` — that shows the real system prompt,
  /// which a passive diagnostic must never trigger as a side effect.
  ///
  /// Bounded by an explicit `.timeout(...)` — unlike `_selfCheckLoad`'s
  /// `AdLoadEvent` wait, a hung platform channel here has no other signal to
  /// race against, and every item in `runIntegrationSelfCheck` is awaited
  /// sequentially, so a channel that never completes would otherwise hang
  /// the entire self-check indefinitely instead of just this one item.
  Future<SelfCheckItem> _selfCheckAtt() async {
    if (!Platform.isIOS) {
      return const SelfCheckItem(
          'ATT status readable (iOS)', SelfCheckStatus.skipped, 'not iOS');
    }
    try {
      final status = await AppTrackingTransparency.trackingAuthorizationStatus
          .timeout(const Duration(seconds: 5));
      return SelfCheckItem('ATT status readable (iOS)', SelfCheckStatus.pass,
          'current=${status.name}');
    } catch (e) {
      return SelfCheckItem(
          'ATT status readable (iOS)',
          SelfCheckStatus.fail,
          'threw: $e — check the app_tracking_transparency plugin is '
              'embedded correctly (pod install / Info.plist)');
    }
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

  /// Override which adapter instance `initialize()` builds, so a test can
  /// observe what happens to it (e.g. that a failed init disposes it) without
  /// a live native plugin. Defaults to the real selection below.
  @visibleForTesting
  static AdProviderAdapter Function(AdConfig config)? debugAdapterFactory;

  /// Inject a VipManager so the VIP-suppression branches are unit-testable.
  @visibleForTesting
  set debugVipManager(VipManager? m) => _vipManager = m;

  /// Inject a (real, bootstrapped) ConsentManager so [_maybeScheduleConsentDialog]
  /// can be exercised without running native [initialize].
  @visibleForTesting
  set debugConsentManager(ConsentManager? m) => _consentManager = m;

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

  /// When set, the `autoRequestUmpConsent` branch throws this instead of
  /// actually calling [requestUmpConsent] — lets tests drive the fail-open
  /// ([MissingPluginException]) vs fail-closed (anything else) branch of the
  /// `runZonedGuarded` error handler without a real UMP channel or a real
  /// consent-fetch failure. See that handler's comments for why the split
  /// matters (compliance: fail-closed unless UMP is provably not wired).
  @visibleForTesting
  Object? debugForceAutoUmpError;

  /// Lets a test exercise the release-build behaviour of
  /// [umpFailureMayReopenGate] from a debug test binary.
  @visibleForTesting
  static bool debugSimulateReleaseModeForUmpGate = false;

  /// Whether a failure of the SDK-owned UMP flow may REOPEN the ad gate.
  ///
  /// Round-7 audit, MAJOR. A [MissingPluginException] used to reopen the gate
  /// unconditionally, on the reading that a missing UMP channel means "this
  /// host never wired google_mobile_ads, so UMP is not in play". That reading
  /// does not hold in a shipped app: `google_mobile_ads` is a hard dependency
  /// of this package and Flutter registers its channels automatically, for the
  /// AppLovin provider too. So in a release build a missing UMP channel means
  /// the native integration is broken — not that the user is outside the EEA
  /// and not that consent is unnecessary. Reopening the gate there serves ads
  /// with no verified consent decision at all, which is the exact GDPR
  /// exposure the fail-closed branch below exists to avoid.
  ///
  /// It stays fail-open in debug/profile because that is where a missing
  /// channel really is routine: `flutter test` has no plugin registrant, so
  /// every unit test that runs [initialize] lands here, and a dev running the
  /// example app before `pod install` would otherwise see no ads at all with
  /// no obvious cause. Neither serves a real user, so neither is a compliance
  /// question.
  @visibleForTesting
  static bool umpFailureMayReopenGate(Object e) =>
      e is MissingPluginException &&
      !(kReleaseMode || debugSimulateReleaseModeForUmpGate);

  /// Consent manager — `null` until [initialize] completes. Owns the
  /// Cupertino consent dialog, persistence, and provider apply pipeline.
  /// Also accessible via static [ConsentManager.instance] once initialised.
  ConsentManager? get consentManager => _consentManager;

  /// Active consent flags. Default conservative until [setConsent] is called.
  AdConsent get consent => _consent;

  /// The consent state most recently pushed down to the adapter.
  ///
  /// B1 — kept separately from [_consent] precisely because `_consent` is
  /// assigned *before* the listener that applies it runs, which makes it
  /// useless for "did this change downgrade anything?". Only
  /// [_syncConsentToAdapter] writes this.
  AdConsent? _lastAppliedConsent;

  /// Last config passed to a successful [initialize]. See M2 in [setConsent]:
  /// `_config` is nulled by adapter teardown, which used to make the COPPA
  /// re-init path unreachable exactly when it was needed.
  AdConfig? _lastKnownConfig;

  /// Raw IAB TCF v2.3 consent string that Google UMP writes to native storage
  /// after a user completes the EEA consent form, or `null` if no TCF session
  /// has run yet (non-EEA users, or UMP never requested).
  Future<String?> get tcfConsentString => IabStorage.read(
        IabStorage.keyTcfString,
      );

  /// Raw IAB Global Privacy Platform header string (the US-states signal), or
  /// `null` if no CMP has written one. See [IabStorage] — the SDK deliberately
  /// does not decode it.
  Future<String?> get gppConsentString => IabStorage.read(
        IabStorage.keyGppString,
      );

  /// Whether the IAB US Privacy string says this user opted out of sale, or
  /// `null` when no such string exists (which is not the same answer).
  ///
  /// m10 (round 5 audit) — `AdConsent.doNotSell` is only ever set by the host,
  /// so [exportComplianceReport] reported `doNotSell: false` for a California
  /// user who had opted out through a CMP. Both native SDKs read the real
  /// signal themselves, so ads behaved correctly; the compliance report was
  /// the thing that lied. Hosts can now reconcile the two.
  Future<bool?> get usPrivacyOptedOut => IabStorage.usPrivacyOptedOut();

  /// Stream of every [AdEvent] (load / show / click / reward / revenue).
  Stream<AdEvent> get events => _eventStream.stream;
  StreamController<AdEvent> _eventStream =
      StreamController<AdEvent>.broadcast();

  /// Persisted log backing [exportComplianceReport] (T23). `null` until
  /// [initialize] completes.
  AdEventLog? _eventLog;

  /// T70 — test seam so didChangeAppLifecycleState's flush-on-pause wiring
  /// can be verified without needing a full SDK init.
  @visibleForTesting
  set debugEventLog(AdEventLog? log) => _eventLog = log;

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

  /// T96 — [exportComplianceReport] plus an on-device Ed25519 signature over
  /// the exact exported JSON (tamper-evidence for a dispute appeal — see
  /// [SignedComplianceReport]'s doc comment for the precise threat model).
  /// Verify with `verifySignedComplianceReportJson` or
  /// `tool/verify_compliance_report.dart`.
  Future<SignedComplianceReport> exportSignedComplianceReport({
    DateTime? from,
    DateTime? to,
  }) {
    return signComplianceReport(exportComplianceReport(from: from, to: to));
  }

  /// Increments on every successful [initialize]. Widgets can listen so they
  /// rebuild after a provider hot-swap or destroy → re-init cycle.
  final ValueNotifier<int> initRevision = ValueNotifier<int>(0);

  /// Increments when the user withdraws personalisation consent while ads are
  /// already on screen (MJ6 / M1). Inline ad widgets listen and drop their
  /// live instance so the next load carries the new consent state.
  ///
  /// Separate from [initRevision] on purpose: that one means "the SDK
  /// re-initialised", and its widget listeners deliberately only act when the
  /// widget has no ad — which is exactly the case this signal is NOT about.
  final ValueNotifier<int> personalisationRevision = ValueNotifier<int>(0);

  /// 0-100 real-time policy risk score (T24) blending CTR anomaly, decayed
  /// suspicious-violation history and resume spam. Dev/partner dashboard
  /// signal only — never shown to end-users, never consulted by the ad-gate
  /// logic. Safe to read pre-init (starts at 0).
  ValueListenable<int> get policyRiskScore => AdSafetyConfig.policyRiskScore;

  // ─── Common state ────────────────────────────────────────────────────────

  String _currentDeviceGAID = '';

  /// Test seam for [_currentDeviceGAID] — real init fetches it via a
  /// platform channel unavailable under `flutter test`.
  @visibleForTesting
  set debugCurrentDeviceGAID(String value) => _currentDeviceGAID = value;

  /// Placeholder GAID Android/iOS return in place of a real one once Limit
  /// Ad Tracking (or ATT-denied) suppresses it — never a real device's GAID,
  /// so callers should treat it the same as "no GAID" rather than a value.
  static const _zeroGaid = '00000000-0000-0000-0000-000000000000';

  /// Current device's GAID, resolved during [initialize]. Empty string
  /// before init completes, when the device has Limit Ad Tracking on, or
  /// when ATT/consent hasn't cleared the platform to hand one over — all of
  /// which the platform itself may report as [_zeroGaid] rather than an
  /// empty string, so that placeholder is normalized to `''` here too.
  ///
  /// **Not the AdMob test-device hash below** — a different Google ID with
  /// no public formula, only usable for this SDK's own VIP whitelist and
  /// AppLovin MAX's `setTestDeviceAdvertisingIds`. Mixing the two up sends
  /// QA devices live production ads instead of test ads.
  String get currentDeviceGaid {
    final gaid = _currentDeviceGAID.trim();
    return gaid.toLowerCase() == _zeroGaid ? '' : gaid;
  }

  /// Instructions for finding this device's AdMob test-device hash — the
  /// opaque hex string `RequestConfiguration.setTestDeviceIds()` needs.
  ///
  /// Google Mobile Ads has no public API or formula for this value: it only
  /// ever surfaces once, printed by the native SDK itself to the platform
  /// log (Android logcat tag `Ads`; iOS: the same message from the native
  /// Google Mobile Ads SDK in the Xcode/Console log) the first time this
  /// device requests an ad and isn't already recognized as a test device —
  /// works identically in debug and release builds since it's the native
  /// ad-serving SDK doing the printing, not this package. Call this to
  /// render that guidance in your own debug UI alongside [currentDeviceGaid]
  /// (labeled separately, since the two are not interchangeable).
  String adMobTestDeviceHashHint() {
    final gaid = currentDeviceGaid;
    final gaidLabel =
        gaid.isEmpty ? '(not resolved yet, or Limit Ad Tracking is on)' : gaid;
    return 'AdMob test-device hash has no public formula — trigger one ad '
        'request on this device, then check the platform log for tag "Ads" '
        '(Android logcat; iOS Xcode/Console shows the same message):\n'
        '  I Ads: Use RequestConfiguration.Builder().setTestDeviceIds('
        'Arrays.asList("<HASH>")) to get test ads on this device.\n'
        'That <HASH> is the value for setTestDeviceIds(). '
        'This device\'s GAID ($gaidLabel) is a different ID and is '
        'NOT valid there.';
  }

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

  // T65 (phase 2) — keyed by widget instance, same reasoning as native's
  // _lastNativeLoadAtByKey.
  final Map<Object, int> _lastBannerLoadAtByKey = {};
  static const int _bannerLoadCooldownMs = 5000;

  // T65 (phase 3) — keyed by widget instance, same reasoning as banner's
  // _lastBannerLoadAtByKey.
  final Map<Object, int> _lastMrecLoadAtByKey = {};
  static const int _mrecLoadCooldownMs = 5000;

  // T65 (phase 1) — keyed by widget instance. This is a per-slot reload
  // debounce (stop one widget's own rebuild loop from spamming reload
  // attempts), NOT a shared policy budget like AdSafetyConfig's daily/hourly
  // caps — so unlike those, it must NOT be shared across simultaneous
  // NativeAdWidget instances, or a feed's 2nd+ item would always start out
  // wrongly "on cooldown" because some OTHER item just loaded.
  final Map<Object, int> _lastNativeLoadAtByKey = {};
  static const int _nativeLoadCooldownMs = 5000;

  // T65 (phase 2) — SDK-init/VIP-expiry/reconnect proactively warm up a
  // banner ahead of any widget mounting (so the first BannerAdWidget an app
  // shows doesn't pay the full network-load latency). There's no widget key
  // at those call sites, so they share this one sentinel key. A widget that
  // later mounts still uses its own `this`-derived key (see
  // BannerAdWidget._initBanner) — known trade-off: this sentinel's preloaded
  // view isn't handed off to that widget, so the common single-banner case
  // pays for two preloads (warm-up + the widget's own) instead of one. Real
  // value is preserved for the tested behavior this replaces (reconnect
  // must still trigger a preload attempt even with zero widgets mounted).
  static final Object _globalBannerWarmupKey = Object();

  /// T65 (phase 3) — same rationale as [_globalBannerWarmupKey], for MREC.
  static final Object _globalMrecWarmupKey = Object();

  bool _retryTimerActive = false;
  int _retryGen = 0;

  // ─── Init-failure auto-retry ──────────────────────────────────────────────
  // A transient failure of `adapter.initialize()` (cold network, brief native
  // SDK hiccup) previously left the SDK permanently un-initialised for the
  // rest of the app session — `_startAdRetryTimer`/`_startConnectivityWatch`
  // only start on the *success* path, so nothing ever retried `initialize()`
  // itself. Bounded backoff retry closes that gap without risking an
  // infinite retry loop on a persistently broken host config.
  static const int _maxInitRetryAttempts = 3;
  static const List<Duration> _initRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  int _initRetryAttempts = 0;
  Timer? _initRetryTimer;
  bool _isInternalInitRetryCall = false;

  /// T80 — regression seam for the 2.0.1 fix: simulates an internal retry
  /// timer firing while another `initialize()` call already holds the busy
  /// guard (`_isInitializing`) — the exact race that used to strand
  /// `_isInternalInitRetryCall` at `true` forever, since the flag was read
  /// AFTER the early-return guard instead of before it.
  @visibleForTesting
  void debugSimulateInternalRetryRaceWithBusyGuard() {
    _isInitializing = true;
    _isInternalInitRetryCall = true;
  }

  /// Test seam for [_isInternalInitRetryCall].
  @visibleForTesting
  bool get debugIsInternalInitRetryCall => _isInternalInitRetryCall;

  // ─── Connectivity watch (T08) ─────────────────────────────────────────────
  StreamSubscription<bool>? _connectivitySub;
  Timer? _reconnectDebounceTimer;

  /// Guards the race in [_startConnectivityWatch] below (2026-08-16 audit).
  int _connectivityWatchGen = 0;

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

  /// Test seam: injectable native init call so tests can simulate a hung
  /// `ConnectionNotifierTools.initialize()` without a real platform channel.
  Future<void> Function() _connectivityInit =
      ConnectionNotifierTools.initialize;

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

  @visibleForTesting
  void debugRetryRefillAds() => _retryRefillAds();

  /// Test seam: inject a fake `ConnectionNotifierTools.initialize()` so tests
  /// can simulate a hung native init call (R10-D) without a real platform
  /// channel.
  @visibleForTesting
  set debugConnectivityInit(Future<void> Function() fn) =>
      _connectivityInit = fn;

  /// Test seam: read whether `_startConnectivityWatch` has completed.
  @visibleForTesting
  bool get debugConnectivityReady => _connectivityReady;

  @visibleForTesting
  int get debugConnectivityWatchGen => _connectivityWatchGen;

  /// Test seam: drive `_startConnectivityWatch` directly without a full
  /// [initialize].
  @visibleForTesting
  Future<void> debugStartConnectivityWatch() => _startConnectivityWatch();

  /// Test seam: drive `_stopConnectivityWatch` directly.
  @visibleForTesting
  void debugStopConnectivityWatch() => _stopConnectivityWatch();

  /// Test seam: whether a live connectivity subscription is currently held
  /// (2026-08-16 audit — proves an overlapping `_startConnectivityWatch`
  /// call that lost the race never resurrects one).
  @visibleForTesting
  bool get debugHasConnectivitySubscription => _connectivitySub != null;

  // ─── Consent gate (T01) ────────────────────────────────────────────────────
  /// Whether ad requests are permitted by the consent flow, mirroring Google
  /// UMP's `ConsentInformation.canRequestAds()`. Defaults `true` so non-UMP
  /// hosts and non-EEA users are unaffected; flips `false` only when UMP reports
  /// the user (EEA, form dismissed) has not granted a basis to request ads.
  /// Google policy: **never** request an ad while this is `false`.
  bool _canRequestAds = true;

  /// Audit fix — reactive mirror of [_canRequestAds]. [BannerAdWidget],
  /// [MrecAdWidget] and [NativeAdWidget] subscribe to this so an
  /// already-mounted, already-loaded instance auto-disposes the moment
  /// consent is revoked mid-session, instead of only ever checking the gate
  /// once on first mount (which left a stale ad — and, on AppLovin, its
  /// native auto-refresh ticker — running with no verified consent basis).
  /// Every write to [_canRequestAds] must go through [_updateCanRequestAds]
  /// so this stays in sync.
  final ValueNotifier<bool> _canRequestAdsNotifier = ValueNotifier<bool>(true);

  /// See [_canRequestAdsNotifier].
  ValueListenable<bool> get canRequestAdsListenable => _canRequestAdsNotifier;

  void _updateCanRequestAds(bool value) {
    _canRequestAds = value;
    if (_canRequestAdsNotifier.value != value) {
      _canRequestAdsNotifier.value = value;
    }
  }

  /// N2 — real runtime block for the consent-coverage footgun (release
  /// builds only; see [consentFootgunWarning]). Kept separate from
  /// [_canRequestAds] because that field's true/false meaning is owned by
  /// the UMP flow's actual result — merging the two would let the reopen
  /// logic in [setConsent] stomp on a real "EEA user hasn't granted" `false`.
  bool _footgunBlocked = false;

  /// See [_canRequestAds] / [_footgunBlocked].
  bool get canRequestAds => _canRequestAds && !_footgunBlocked;

  /// True when ANY fullscreen surface already owns the screen — an App Open,
  /// interstitial or rewarded ad, the SDK's own loading buffer, or a host
  /// dialog/popup.
  ///
  /// One shared predicate for every `show*` path, because each path used to
  /// carry its own subset and they had drifted: `showAppOpenAdOnResume` checked
  /// the other two slots plus the dialog stack, while `showInterstitial` and
  /// `showRewarded` each checked only themselves — so an interstitial could be
  /// shown on top of a rewarded ad and vice versa. Stacking one fullscreen ad
  /// on another is an AdMob and AppLovin policy violation, and
  /// `AdSafetyConfig.canShowFullscreenAd()` cannot substitute: that is a
  /// time-based frequency gate, not a state-based mutex.
  ///
  /// Keeping it in one place also means a fifth ad type added later is covered
  /// by construction rather than by remembering to copy the condition.
  String? get _fullscreenBusyReason {
    // Round-7 audit, MAJOR — checked before the adapter, because the initial
    // consent form is presented during splash while the adapter may not exist
    // yet. Google's UMP form is a native activity/view controller, not a
    // Flutter route, so `AdScreenRouteLogger.isDialogOnTop` below cannot see
    // it and nothing stopped a fullscreen ad from covering the consent form:
    // the user's tap lands on the ad, the consent choice never gets made, and
    // an ad drawn over a consent dialog is a policy violation on its own. The
    // form also does not background the app, so the App Open resume guard was
    // never in the picture either.
    if (umpFormOnScreen.value) return 'a consent form is on screen';
    final ad = _adapter;
    if (ad == null) return null;
    if (ad.appOpenSlot.isShowing) return 'app-open ad currently showing';
    if (ad.interstitialSlot.isShowing) return 'interstitial currently showing';
    if (ad.rewardedSlot.isShowing) return 'rewarded ad currently showing';
    // M1 fix (audit_claude.md, 2026-08-20): was missing here, so a rewarded
    // interstitial could show while another fullscreen ad was already up —
    // ad stacking, a policy violation on both AdMob and AppLovin.
    if (ad.rewardedInterstitialSlot.isShowing) {
      return 'rewarded interstitial currently showing';
    }
    if (AdLoadingDialog.isShowing) return 'ad loading buffer showing';
    if (AdScreenRouteLogger.isDialogOnTop) return 'a dialog/popup is on top';
    return null;
  }

  /// Test seam for [_fullscreenBusyReason].
  @visibleForTesting
  String? get debugFullscreenBusyReason => _fullscreenBusyReason;

  /// T75 — public, read-only mirror of [_fullscreenBusyReason] (as a plain
  /// `bool`) so a host app can disable its own fullscreen-ad CTA or avoid
  /// opening a competing dialog while the SDK's mutex is held, instead of
  /// only being able to check it at the moment it calls a show method.
  ///
  /// Kept in sync by [_recomputeFullscreenBusy], called whenever any of
  /// [_fullscreenBusyReason]'s six inputs changes: the four fullscreen ad
  /// slots (via [_attachFullscreenBusySlotListeners], re-wired on every
  /// adapter swap by the `_adapter` setter above), [AdLoadingDialog]'s and
  /// [AdScreenRouteLogger]'s own notifiers (wired once in [_internal]).
  final ValueNotifier<bool> fullscreenBusy = ValueNotifier<bool>(false);

  void _recomputeFullscreenBusy() {
    fullscreenBusy.value = _fullscreenBusyReason != null;
  }

  void _attachFullscreenBusySlotListeners() {
    final ad = _adapterField;
    if (ad == null) return;
    ad.appOpenSlot.state.addListener(_recomputeFullscreenBusy);
    ad.interstitialSlot.state.addListener(_recomputeFullscreenBusy);
    ad.rewardedSlot.state.addListener(_recomputeFullscreenBusy);
    ad.rewardedInterstitialSlot.state.addListener(_recomputeFullscreenBusy);
  }

  void _detachFullscreenBusySlotListeners() {
    final ad = _adapterField;
    if (ad == null) return;
    ad.appOpenSlot.state.removeListener(_recomputeFullscreenBusy);
    ad.interstitialSlot.state.removeListener(_recomputeFullscreenBusy);
    ad.rewardedSlot.state.removeListener(_recomputeFullscreenBusy);
    ad.rewardedInterstitialSlot.state.removeListener(_recomputeFullscreenBusy);
  }

  /// T76 — the on-demand rewarded path (`_loadRewardedOnDemand`) already has
  /// its own timeout; a REGULAR preload (`loadInterstitial`/`loadRewardedAd`/
  /// `loadAppOpenAd`) had none — if the native SDK's callback never fires,
  /// [slot] is stuck in [AdSlotState.loading] forever, never retried by the
  /// existing backoff logic (which only reacts to [AdSlot.markFailed]).
  ///
  /// Only forces a fail if [slot] is STILL loading when the timer fires —
  /// if the native callback already resolved it (ready or cooldown), this
  /// is a no-op so a genuinely-loaded ad is never clobbered by a late timer.
  /// T77 — structured twin of the `SafeLogger.d('⏭️ ... skipped — ...')`
  /// lines throughout this file, so a host can build a gate/skip funnel
  /// dashboard without parsing log text. [providerTag] defaults to a
  /// `'[SDK]'` sentinel for the "adapter null" case, where no real
  /// provider tag exists yet.
  void _emitSkip(
    AdSlotType type,
    String action,
    String reason, {
    AdPlacement placement = AdPlacement.unspecified,
    String? providerTag,
  }) {
    _emit(AdSkipEvent(
      providerTag: providerTag ?? _adapter?.tag ?? '[SDK]',
      type: type,
      placement: placement,
      action: action,
      reason: reason,
    ));
  }

  void _armLoadWatchdog(String label, AdSlot slot, Duration timeout) =>
      slot.armLoadWatchdog(label, timeout);

  /// Test seam for the consent gate.
  @visibleForTesting
  set debugCanRequestAds(bool v) => _updateCanRequestAds(v);

  /// N2 test seam — forces the release-only footgun block without needing a
  /// `kReleaseMode` build.
  @visibleForTesting
  set debugFootgunBlocked(bool v) => _footgunBlocked = v;

  @visibleForTesting
  bool get debugFootgunBlocked => _footgunBlocked;

  /// The actual isRelease-gated decision from [initialize]'s consent-coverage
  /// footgun (see the call site right after [consentFootgunWarning] returns
  /// non-null). Factored out so [debugApplyConsentFootgunGuard] can exercise
  /// it directly — a real [initialize] call never completes under
  /// `flutter test` (no native adapter), so this branch was otherwise
  /// unreachable by any test despite `isRelease` being threaded to it.
  void _applyConsentFootgunGuard(bool isRelease) {
    if (isActuallyRelease(isRelease)) _footgunBlocked = true;
  }

  /// Test seam for [_applyConsentFootgunGuard] — see its doc comment.
  @visibleForTesting
  void debugApplyConsentFootgunGuard(bool isRelease) =>
      _applyConsentFootgunGuard(isRelease);

  /// Whether [requestUmpConsent] has ever run this process — used to detect the
  /// "no consent form anywhere" footgun at [initialize] time (AppLovin CMP off +
  /// UMP never run). Runtime state, so it doesn't false-alarm hosts that gather
  /// consent correctly in their splash.
  bool _umpRequested = false;

  /// m6 — whether an auto-UMP flow has been *started* this process, as opposed
  /// to [_umpRequested] which only flips once one has completed. Read by the
  /// consent-footgun check, which runs while the un-awaited auto flow may
  /// still be in flight. Kept separate because [_umpRequested] also gates
  /// `requestUmpConsent(skipIfAlreadyRequested: true)`'s early return.
  bool _umpFlowStarted = false;

  /// M7 (independent review) — set when our own dismiss timeout fired while a
  /// consent form was (as far as we know) still on screen. `Future.timeout`
  /// does not close the native form, so the periodic backstop would otherwise
  /// call `loadAndShowConsentFormIfRequired` again on top of it — the very
  /// "two forms in a row" symptom MJ8's mutex was meant to prevent, except the
  /// mutex is already released by then. Only a reconnect or an explicit host
  /// call may retry after this.
  bool _umpFormAbandoned = false;

  /// Last result returned by [requestUmpConsent] this process, so the
  /// auto-request path (`skipIfAlreadyRequested: true`) can hand back what the
  /// host already obtained instead of inventing a value or re-running the flow.
  UmpConsentResult? _lastUmpResult;

  /// True when the last [requestUmpConsent] attempt failed (network error or
  /// the 20s timeout) — retried by [_onConnectivityChanged] on the next
  /// offline→online transition, and as a backstop by [_scheduleNextRetry]'s
  /// periodic poll for platforms/tests where the connectivity plugin never
  /// fires that transition.
  bool _umpAttemptFailed = false;

  /// Test seam for [_umpAttemptFailed].
  @visibleForTesting
  bool get debugUmpAttemptFailed => _umpAttemptFailed;

  /// Test seam for [_umpAttemptFailed] — see [debugResetGuardState].
  @visibleForTesting
  set debugUmpAttemptFailed(bool v) => _umpAttemptFailed = v;

  @visibleForTesting
  bool get debugUmpFormAbandoned => _umpFormAbandoned;

  /// Test seam for [_recheckAbandonedUmpForm] (M-3) — the periodic backstop
  /// and reconnect call sites are themselves timer/plugin-driven and out of
  /// proportion to drive in a test just to reach this; this calls the real
  /// method directly.
  @visibleForTesting
  Future<void> debugRecheckAbandonedUmpForm() => _recheckAbandonedUmpForm();

  /// Counts [_scheduleNextRetry]'s periodic UMP backstop firing — driving the
  /// real [requestUmpConsent] round trip in a test needs a full UMP channel
  /// mock (out of proportion here, see other UMP tests), so this is the test
  /// seam for "did the backstop actually retry".
  int _umpBackstopRetryCount = 0;

  @visibleForTesting
  int get debugUmpBackstopRetryCount => _umpBackstopRetryCount;

  /// m11 — cap on [_scheduleNextRetry]'s UMP backstop. 5 attempts at the 5 min
  /// poll interval covers the first ~25 minutes, which is well past any real
  /// "flaky network on first launch"; the reconnect path stays available for
  /// anything later. Same bounded-retry shape as [_maxInitRetryAttempts] and
  /// AdSlot's backoff — an unbounded auto-retry that can present UI is exactly
  /// what this guard exists to prevent.
  static const int _maxUmpBackstopRetries = 5;

  /// Params of the most recent [requestUmpConsent] call, replayed by
  /// [_retryUmpConsent].
  ///
  /// MJ3 (round 5 audit) — both retry sites used to call `requestUmpConsent()`
  /// with no arguments, silently dropping `tagForUnderAgeOfConsent`: a
  /// child-directed app that hit a retry then gathered consent through the
  /// wrong form, and the consent it collected was not valid for an under-age
  /// audience. It also dropped `debugGeography`/`testIdentifiers`, which made
  /// a failed EEA-debug run impossible to reproduce.
  ({
    bool testMode,
    DebugGeography? debugGeography,
    List<String> testIdentifiers,
    bool tagForUnderAgeOfConsent,
  })? _lastUmpParams;

  /// In-flight [requestUmpConsent] call, so concurrent callers join it instead
  /// of starting a second consent flow.
  ///
  /// MJ8 (round 5 audit) — `_umpRequested` is only set *after* the round trip
  /// completes, so the reconnect path, the periodic backstop and a host's own
  /// call could each start their own flow: two consent forms in a row, and two
  /// racing writes to the gate and to persisted consent. The BL1 fix makes the
  /// retry paths fire more often, so this stopped being theoretical.
  Future<UmpConsentResult>? _umpInFlight;

  /// Test seam for [_umpRequested] — see [debugResetGuardState].
  @visibleForTesting
  set debugUmpRequested(bool v) => _umpRequested = v;

  @visibleForTesting
  bool get debugUmpRequested => _umpRequested;

  /// N2 — set true by [setConsent] itself, so the footgun check doesn't
  /// false-block hosts running their OWN non-UMP consent UI who hand the
  /// answer straight to [setConsent] instead of calling [requestUmpConsent].
  bool _consentExplicitlySet = false;

  /// Test seam for [_consentExplicitlySet] — see [debugResetGuardState].
  @visibleForTesting
  set debugConsentExplicitlySet(bool v) => _consentExplicitlySet = v;

  @visibleForTesting
  bool get debugConsentExplicitlySet => _consentExplicitlySet;

  /// F9 — set by [requestAtt]; used only to warn (never block) when
  /// [requestUmpConsent] runs on iOS before ATT was requested, since callers
  /// are only supposed to know the correct order via docstrings today.
  bool _attRequested = false;

  /// M9 (audit_claude.md, 2026-08-20) — true when [initialize] skipped its
  /// device-GAID fetch because ATT was still undecided and the host hadn't
  /// called [requestAtt] yet. Set so [requestAtt] can resolve the GAID (and
  /// re-run the config VIP-GAID whitelist check) once ATT is actually
  /// decided, instead of never resolving it at all.
  bool _gaidFetchDeferredForAtt = false;

  /// Test seam: clear the banner load cooldown so tests sharing the singleton
  /// don't leak `_lastBannerLoadAt` into each other.
  @visibleForTesting
  void debugResetBannerCooldown() => _lastBannerLoadAtByKey.clear();

  /// Test seam: same as [debugResetBannerCooldown] but for MREC.
  @visibleForTesting
  void debugResetMrecCooldown() => _lastMrecLoadAtByKey.clear();

  /// Test seam: same as [debugResetBannerCooldown] but for Native.
  @visibleForTesting
  void debugResetNativeCooldown() => _lastNativeLoadAtByKey.clear();

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
    // m9 (round 5 audit) — never run two consent flows at once. This built-in
    // dialog is a plain two-button sheet: it is NOT a Google-certified CMP and
    // produces no TCF consent string, so a "yes" collected here is not a valid
    // legal basis in the EEA — yet it was written straight through to
    // AppLovin's setHasUserConsent. The path in was easy to hit: when UMP came
    // back inconclusive (no network) requestUmpConsent deliberately leaves the
    // persisted value alone, so `hasBeenAsked` stayed false and this dialog
    // then asked an EEA user itself. If UMP owns consent, it owns it in every
    // outcome — including the ones where it could not decide.
    if (cfg.autoRequestUmpConsent || _umpRequested || _umpFlowStarted) {
      SafeLogger.d(
          _tag,
          '⏭️ consent dialog skipped — UMP is the consent source '
          '(the built-in dialog is not a TCF CMP)');
      return;
    }
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
      // T60 — the built-in dialog is itself a resolved consent flow, same
      // as an explicit setConsent() call (see its N2 comment above): a host
      // with `autoRequestUmpConsent: false` that relies on this dialog
      // instead of calling requestUmpConsent()/setConsent() manually would
      // otherwise stay footgun-blocked for the rest of the release session
      // even after the user answered.
      _consentExplicitlySet = true;
      _footgunBlocked = false;
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

  /// Test seam — clears a previously-set navigator key so
  /// `runIntegrationSelfCheck`'s "Navigator key wired" check (T98) can be
  /// exercised as never-set, independent of test execution order.
  @visibleForTesting
  void debugClearNavigatorKey() => _navigatorKey = null;

  // ─── Banner accessors used by BannerAdWidget ─────────────────────────────

  // T65 (phase 2) — keyed by widget instance, same reasoning as native's
  // canLoadNative: this is a per-slot reload debounce, not a shared policy
  // budget, so it must not be shared across simultaneous BannerAdWidgets.
  bool canLoadBanner(Object key) {
    final last = _lastBannerLoadAtByKey[key];
    if (last == null) return true;
    return DateTime.now().millisecondsSinceEpoch - last >=
        _bannerLoadCooldownMs;
  }

  void recordBannerLoad(Object key) {
    _lastBannerLoadAtByKey[key] = DateTime.now().millisecondsSinceEpoch;
  }

  ValueListenable<bool> bannerIsLoaded(Object key) =>
      _adapter?.banner(key).isLoaded ?? _stubBoolFalse;

  ValueListenable<bool> bannerHasError(Object key) =>
      _adapter?.banner(key).hasError ?? _stubBoolFalse;

  ValueListenable<Size?> bannerAdSize(Object key) =>
      _adapter?.banner(key).adSize ?? _stubSize;

  ValueListenable<bool> bannerAutoRefreshEnabled(Object key) =>
      _adapter?.banner(key).autoRefreshEnabled ?? _stubBoolTrue;

  ValueListenable<bool> bannerVisible(Object key) =>
      _adapter?.banner(key).visible ?? _stubBoolTrue;

  ValueListenable<Object?> bannerAdViewId(Object key) =>
      _adapter?.appLovinBannerAdViewId(key) ?? _stubObject;

  String get appLovinBannerId => _adapter?.appLovinBannerId ?? '';

  bool bannerRoutePaused(Object key) =>
      _adapter?.bannerRoutePaused(key) ?? false;

  void setBannerRoutePaused(Object key, bool paused) =>
      _adapter?.setBannerRoutePaused(key, paused);

  Widget? admobBannerView(Object key) => _adapter?.buildAdmobBannerView(key);

  /// AppLovin only — AdMob's banner loads lazily via [loadAdmobBannerIfNeeded]
  /// once the widget knows its width; this is a no-op there.
  Future<void> preloadBanner(Object key) =>
      _adapter?.preloadBanner(key) ?? Future<void>.value();

  void disposeBannerInstance(Object key) {
    _adapter?.disposeBannerInstance(key);
    _lastBannerLoadAtByKey.remove(key);
  }

  // ─── MREC accessors used by MrecAdWidget ─────────────────────────────────

  // T65 (phase 3) — keyed by widget instance, same reasoning as banner's
  // canLoadBanner.
  bool canLoadMrec(Object key) {
    final last = _lastMrecLoadAtByKey[key];
    if (last == null) return true;
    return DateTime.now().millisecondsSinceEpoch - last >= _mrecLoadCooldownMs;
  }

  void recordMrecLoad(Object key) {
    _lastMrecLoadAtByKey[key] = DateTime.now().millisecondsSinceEpoch;
  }

  ValueListenable<bool> mrecIsLoaded(Object key) =>
      _adapter?.mrec(key).isLoaded ?? _stubBoolFalse;

  ValueListenable<bool> mrecHasError(Object key) =>
      _adapter?.mrec(key).hasError ?? _stubBoolFalse;

  ValueListenable<Size?> mrecAdSize(Object key) =>
      _adapter?.mrec(key).adSize ?? _stubSize;

  ValueListenable<bool> mrecAutoRefreshEnabled(Object key) =>
      _adapter?.mrec(key).autoRefreshEnabled ?? _stubBoolTrue;

  ValueListenable<bool> mrecVisible(Object key) =>
      _adapter?.mrec(key).visible ?? _stubBoolTrue;

  ValueListenable<Object?> mrecAdViewId(Object key) =>
      _adapter?.appLovinMrecAdViewId(key) ?? _stubObject;

  String get appLovinMrecId => _adapter?.appLovinMrecId ?? '';

  bool mrecRoutePaused(Object key) => _adapter?.mrecRoutePaused(key) ?? false;

  void setMrecRoutePaused(Object key, bool paused) =>
      _adapter?.setMrecRoutePaused(key, paused);

  Widget? admobMrecView(Object key) => _adapter?.buildAdmobMrecView(key);

  /// AppLovin only — AdMob's MREC loads lazily via [loadAdmobMrecIfNeeded]
  /// once the widget knows its width; this is a no-op there.
  Future<void> preloadMrec(Object key) =>
      _adapter?.preloadMrec(key) ?? Future<void>.value();

  void disposeMrecInstance(Object key) {
    _adapter?.disposeMrecInstance(key);
    _lastMrecLoadAtByKey.remove(key);
  }

  // ─── Native accessors used by NativeAdWidget ─────────────────────────────

  bool canLoadNative(Object key) {
    final last = _lastNativeLoadAtByKey[key];
    if (last == null) return true;
    return DateTime.now().millisecondsSinceEpoch - last >=
        _nativeLoadCooldownMs;
  }

  void recordNativeLoad(Object key) {
    _lastNativeLoadAtByKey[key] = DateTime.now().millisecondsSinceEpoch;
    // NativeAdWidget calls this on every mount AND every re-init (withdrawn
    // personalisation, consent gate reopening), so it is the one signal that
    // says "a live widget owns this key again" as opposed to "a late callback
    // for a widget that is gone" — which is exactly what AppLovinAdapter's
    // native tombstone needs to tell apart. Without lifting it here the
    // re-inited widget keeps getting a permanently-disposed bundle back.
    // AdMob has no tombstone to lift (slot identity guards it instead).
    final adapter = _adapter;
    if (adapter is AppLovinAdapter) adapter.reviveNativeInstance(key);
  }

  // T65 (phase 1) — keyed by widget instance (see AdProviderAdapter.nativeSlot).
  ValueListenable<bool> nativeIsLoaded(Object key) =>
      _adapter?.native(key).isLoaded ?? _stubBoolFalse;

  ValueListenable<bool> nativeHasError(Object key) =>
      _adapter?.native(key).hasError ?? _stubBoolFalse;

  String get appLovinNativeId => _adapter?.appLovinNativeId ?? '';

  Widget? admobNativeView(Object key) => _adapter?.buildAdmobNativeView(key);

  void disposeNativeInstance(Object key) {
    _adapter?.disposeNativeInstance(key);
    _lastNativeLoadAtByKey.remove(key);
  }

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

  /// Fetches [_currentDeviceGAID] via the `advertising_id` plugin. Callable
  /// from [initialize] directly, or from [requestAtt] when M9's defer above
  /// kicked in.
  Future<void> _resolveDeviceGaid() async {
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
  }

  /// First-init: import VIP GAIDs from `config.vipDeviceGaids` (release
  /// builds only). Only entries whose GAID matches THIS device (per
  /// [_currentDeviceGAID]) are persisted as active VIP — matching 1.x
  /// behaviour exactly. No-op once already run (`isAddVIPMemberFirstInitSuccess`).
  Future<void> _applyConfigVipGaidWhitelist(
      AdConfig config, VipManager vip, AdPreferences prefs) async {
    if (prefs.isAddVIPMemberFirstInitSuccess()) return;
    if (kDebugMode || config.vipDeviceGaids.isEmpty) return;
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
    // T88 — optional hook for remotely-controlled AdSafetyParams overrides
    // (Firebase Remote Config, a self-hosted config API, ...). See
    // RemoteAdSafetyProvider's doc comment for the full contract.
    RemoteAdSafetyProvider? remoteSafetyProvider,
    @visibleForTesting bool isRelease = kReleaseMode,
  }) async {
    // Read + clear the internal-retry flag before the early-return guard —
    // otherwise a retry timer firing while another call already holds
    // `_isInitializing` leaves the flag stuck `true` forever (this call
    // returns without ever reaching the reset below), and the next
    // legitimate host-initiated call gets misclassified as an internal
    // retry and skips its retry-budget reset.
    final isInternalRetry = _isInternalInitRetryCall;
    _isInternalInitRetryCall = false;
    // Guard so concurrent calls during a teardown-then-reinit cycle can't
    // slip past `_disposeAdapter`'s await and leak two adapters.
    if (_isInitializing) {
      SafeLogger.w(_tag, 'initialize already in progress — skipping duplicate');
      return;
    }
    _isInitializing = true;
    if (!isInternalRetry) {
      // A fresh, host-initiated call resets the auto-retry budget — otherwise
      // a legitimate manual retry right after the internal budget was
      // exhausted would look like it's still "out of retries".
      _initRetryAttempts = 0;
      _initRetryTimer?.cancel();
      _initRetryTimer = null;
    }
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
        // 2026-08-16 audit: ConsentManager itself is a persistent static
        // singleton (`ConsentManager.bootstrap` reuses `_instance` unless
        // `resetForTest()` ran) — surviving THIS re-init just like the
        // adapter is torn down and recreated. Without removing the listener
        // here first, the fresh `addListener(_syncConsentToAdapter)` below
        // would stack onto the SAME live `ConsentManager` instance, so N
        // re-inits (without an intervening destroy()) fire _syncConsentToAdapter
        // N times per consent change.
        _consentManager?.listenable.removeListener(_syncConsentToAdapter);
        // R12-A audit round 6: reset via the same shared method destroy()
        // uses, instead of a hand-copied field list — a second field
        // (_umpRequested/_consentExplicitlySet) leaked past this branch in
        // Round 6 the same way _footgunBlocked did in Round 5, because the
        // two reset lists were maintained independently.
        _resetGuardState();
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
      // T88 — a remote provider gets a bounded window to answer; a slow or
      // failing backend must never block SDK init. Validated + merged onto
      // config.safety — the local values are always the fallback.
      var effectiveSafety = config.safety;
      if (remoteSafetyProvider != null) {
        try {
          final overrides = await remoteSafetyProvider
              .fetchSafetyParamOverrides()
              .timeout(const Duration(seconds: 5));
          if (overrides != null) {
            effectiveSafety =
                applyRemoteSafetyOverrides(config.safety, overrides);
            SafeLogger.d(_tag, '🌐 remote AdSafetyParams overrides applied');
          }
        } catch (e) {
          SafeLogger.w(_tag,
              '⚠️ remoteSafetyProvider failed, using local AdSafetyParams: $e');
        }
      }
      await AdSafetyConfig.init(prefs,
          params: effectiveSafety, isRelease: isRelease);
      AdSafetyConfig.setAnomalySink(_emit); // T25: anomaly/fraud alert stream

      // ── Release footguns (loud, fire in release where it matters) ──────────
      // isDebug: kDebugMode on purpose (not isActuallyRelease()) — these
      // warnings must still fire in profile-mode builds, unlike the
      // isActuallyRelease() call sites below, which gate release-only guards.
      for (final w in releaseFootgunWarnings(config, isDebug: kDebugMode)) {
        SafeLogger.e(_tag, w);
        assert(false, w);
      }

      // Resolve device GAID FIRST — VIP migration + first-init both need it
      // to preserve 1.x's per-device matching semantic (a `vipDeviceGaids`
      // entry only marks the device VIP when its own GAID matches).
      //
      // M9 (audit_claude.md, 2026-08-20) — on iOS, `advertising_id`'s native
      // plugin triggers the real ATT system prompt itself whenever status is
      // still `.notDetermined`, independent of whether the host has decided
      // to call `requestAtt()` yet. Calling it unconditionally here meant
      // initialize() (which the integration contract requires running from
      // splash) could pop the ATT prompt before the host chose to, breaking
      // Apple's "show ATT in the right context" guidance. Read the status
      // first (read-only, no prompt) and defer the fetch — and the
      // GAID-dependent config-whitelist check below — to [requestAtt] when
      // it's still undecided and the host hasn't called requestAtt() yet.
      TrackingStatus? attStatus;
      if (Platform.isIOS && !_attRequested) {
        try {
          // m13 (round 5 audit) — bounded, matching what [_selfCheckAtt]
          // already does to this exact call for exactly this reason: a wedged
          // platform channel would otherwise hang initialize() with no
          // deadline of its own. Together with m7, a timeout now lands as
          // `null` → "unknown" → defer the GAID fetch, which is the safe
          // answer rather than the fast one.
          attStatus = await AppTrackingTransparency.trackingAuthorizationStatus
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          attStatus = null;
        }
      }
      if (shouldDeferGaidFetch(
          isIos: Platform.isIOS,
          attRequested: _attRequested,
          attStatus: attStatus)) {
        _gaidFetchDeferredForAtt = true;
        SafeLogger.d(
            _tag, () => '⏸️ GAID fetch deferred until requestAtt() runs (M9)');
      } else {
        await _resolveDeviceGaid();
      }

      // Phase 4: load VIP manager + auto-migrate (matched against this GAID).
      // Detach + dispose any pre-existing VipManager (re-init path) before
      // wiring a new one — otherwise the old listener would leak.
      _vipManager?.activeListenable.removeListener(_onVipActiveChanged);
      _vipManager?.dispose();
      final vip = VipManager(prefs,
          maxStackDuration: config.maxVipStackDuration,
          isRelease: isRelease,
          isConnectedCheck: () => isConnected);
      await vip.load(currentDeviceGaid: _currentDeviceGAID);
      vip.activeListenable.addListener(_onVipActiveChanged);
      _vipManager = vip;
      _vipReadyNotifier.value = true;
      SafeLogger.d(_tag,
          () => 'VIP active=${vip.isActive} entries=${vip.entries.length}');

      // First-init: import VIP GAIDs from config (release builds only). Only
      // entries whose GAID matches THIS device are persisted as active VIP —
      // matching 1.x behaviour exactly. Skipped when the GAID fetch above was
      // deferred (M9) — [requestAtt] runs it once the real GAID is known, so
      // this doesn't get marked done against an empty GAID.
      if (!_gaidFetchDeferredForAtt) {
        await _applyConfigVipGaidWhitelist(config, vip, prefs);
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
          // skip re-granting. Android: anti-bypass is intentionally
          // disabled — every reinstall grants a fresh grace window (no
          // Install Referrer check; see FirstInstallGuard doc comment for
          // rationale). Falls through to allow grace if no bypass signal
          // is found, so legitimate first-time users still get their
          // grace window.
          final guard = FirstInstallGuard();
          // m13 — bounded: this reads the iOS Keychain through
          // flutter_secure_storage, and a Keychain read can genuinely block
          // (notably before first unlock after a reboot). `true` on timeout is
          // the conservative answer: skip the grant rather than hand out a
          // second trial window to what may be a reinstall.
          final alreadyGranted = await guard
              .hasAlreadyGranted()
              .timeout(const Duration(seconds: 5), onTimeout: () {
            SafeLogger.w(
                _tag,
                'first-install guard read timed out — skipping the grace '
                'grant rather than risking a duplicate');
            return true;
          });
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
            vip.notifyFirstInstallGrant(dur);
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

      // B2 fix (audit_claude.md) — a caller (e.g. requestUmpConsent(), or a
      // host's own setConsent(isAgeRestrictedUser: true) for COPPA) may have
      // run *before* this initialize() call bootstrapped ConsentManager
      // above, in which case it was buffered into _pendingConsentSettings
      // instead of being lost (see [setConsent]). Replay it here — BEFORE
      // the adapter is picked/initialised below — so isAgeRestrictedUser
      // reflects the host's real, already-communicated intent for the very
      // call that gates AppLovin's fail-closed COPPA init. Replaying this
      // after adapter.initialize() (as it used to) let a host's pre-init
      // isAgeRestrictedUser: true arrive too late to gate that init at all.
      final pendingConsent = _pendingConsentSettings;
      if (pendingConsent != null) {
        _pendingConsentSettings = null;
        await consentMgr.set(pendingConsent, config: config);
        _consent = consentMgr.adConsent;
      }

      // R10-A — SDK-owned UMP: run Google's consent flow before the adapter
      // is even picked/initialised, matching requestUmpConsent()'s own
      // docstring (call it before initialize()). Previously this ran AFTER
      // adapter.initialize() below, so AppLovin/AdMob's native init request
      // could go out before EEA/UK consent was known. Safe to run here:
      // ConsentManager was just bootstrapped above, so requestUmpConsent()'s
      // internal setConsent() call takes the direct `_consentManager!.set(...)`
      // path (not the `_pendingConsentSettings` buffer), and `isInitialised`
      // is still false at this point (adapter/`_config` unset), so setConsent
      // early-returns before touching the adapter — nothing to apply yet.
      // Opt-in; hosts that run UMP in their splash leave this false to avoid
      // double-running.
      if (config.autoRequestUmpConsent) {
        SafeLogger.d(
            _tag, '🔐 autoRequestUmpConsent — running UMP before adapter init');
        debugLastAutoUmpParams = {
          'testMode': kDebugMode,
          'tagForUnderAgeOfConsent': config.umpTagForUnderAgeOfConsent,
          'debugGeography': config.umpDebugGeography,
          'testIdentifiers': config.umpTestIdentifiers,
        };
        // C1 — never let the consent SDK take down SDK init. `google_mobile_ads`
        // throws MissingPluginException from requestConsentInfoUpdate when the
        // UMP channel is not registered (unit tests, and any host that has not
        // wired the plugin), and requestUmpConsentFlow only catches UMP's own
        // FormError, not a channel throw. Before autoRequestUmpConsent defaulted
        // to true this was unreachable; now every host hits this line, so a
        // throw here would abort initialize() for everyone.
        //
        // Degrading to "consent not obtained" is the safe direction: the
        // canRequestAds gate keeps whatever UMP had cached, and C2's
        // reconnect retry will try again.
        // A plain try/catch is not enough. `requestConsentInfoUpdate` is a
        // callback API returning void: when the UMP channel is missing it
        // throws MissingPluginException from a future nobody awaits, so the
        // error escapes as an UNHANDLED ZONE ERROR, not on the future we await
        // here. Verified against the real stack — google_mobile_ads'
        // UserMessagingChannel.requestConsentInfoUpdate reached via
        // ump_consent.dart. runZonedGuarded is what actually contains it, and
        // it is scoped to this one call rather than to init as a whole.
        // Do NOT await this. UMP can put a consent form on screen, and the
        // user may take as long as they like — or never respond. Awaiting it
        // stalled initialize() behind that form: CI run 30749745112 showed
        // "consent form dismiss timed out after 20s" with adapter init only
        // starting afterwards, which is a 20-second startup freeze for any
        // real user who leaves the form sitting there.
        //
        // Running it concurrently is only safe because the gate is closed
        // first: with the SDK owning the consent flow, canRequestAds starts
        // false and no load*()/show*() can fire until UMP reports back. The
        // UMP handler then opens the gate and refills the slots that were
        // held. So the SDK becomes ready immediately and ads simply arrive a
        // little later, instead of the whole app waiting.
        //
        // Only when the SDK owns consent. A host that sets
        // autoRequestUmpConsent: false keeps the historical default of true —
        // its own consent flow (or the release footgun guard) governs.
        _updateCanRequestAds(false);
        SafeLogger.d(
            _tag, '🔐 gate closed until UMP resolves (SDK-owned consent flow)');
        // m6 — record that a flow has *started* here, not when it finishes.
        // The auto flow below is deliberately not awaited, so
        // consentFootgunWarning() (which runs a few lines further down) could
        // otherwise fire while UMP was still in flight and warn that no
        // consent flow exists when one was already underway. Deliberately a
        // separate flag from `_umpRequested`: that one gates the
        // skipIfAlreadyRequested early-return, so setting it here would make
        // the call below skip itself and no consent flow would run at all.
        _umpFlowStarted = true;
        runZonedGuarded(() async {
          if (debugForceAutoUmpError != null) {
            throw debugForceAutoUmpError!;
          }
          await requestUmpConsent(
            skipIfAlreadyRequested: true,
            testMode: kDebugMode,
            tagForUnderAgeOfConsent: config.umpTagForUnderAgeOfConsent,
            debugGeography: config.umpDebugGeography,
            testIdentifiers: config.umpTestIdentifiers,
          );
        }, (e, _) {
          // requestConsentInfoUpdate is a callback API returning void: with no
          // UMP channel registered it throws from a future nobody awaits, so
          // the error arrives as an unhandled ZONE error that a try/catch
          // around the call cannot see. Verified against the real stack in
          // google_mobile_ads' UserMessagingChannel.
          _umpAttemptFailed = true;
          // Fail OPEN only for MissingPluginException — that specifically means
          // the UMP channel is not registered (unit tests, or a host that never
          // wired google_mobile_ads), i.e. UMP is not in play for this host at
          // all, which is the non-EEA/non-UMP case the historical default of
          // `true` was written for.
          //
          // Any OTHER exception (network error, malformed response, UMP SDK
          // bug) means the channel IS wired but the consent fetch itself
          // failed — failing open there would ship ads with no verified
          // consent decision, a real GDPR exposure. Stay fail-closed and let
          // the reconnect retry (C2) try again once connectivity/whatever
          // caused it recovers.
          if (umpFailureMayReopenGate(e)) {
            SafeLogger.w(
                _tag,
                'auto UMP failed — no UMP channel registered ($e); reopening '
                'the gate (fail-open) because this is a debug/test build, '
                'where a missing plugin registrant is routine');
            _updateCanRequestAds(true);
          } else if (e is MissingPluginException) {
            // Release build, UMP channel missing — see
            // [umpFailureMayReopenGate]. Loud, because the host has to fix
            // their native integration: ads stay off until they do.
            SafeLogger.critical(
                _tag,
                'auto UMP failed — the UMP channel is NOT registered in a '
                'RELEASE build ($e). google_mobile_ads is a dependency of '
                'this SDK, so this means a broken native integration, not '
                '"UMP is not in play". Consent cannot be verified, so the '
                'gate stays CLOSED and no ads will be requested. Fix the '
                'native integration (pod install / plugin registration).');
          } else {
            SafeLogger.critical(
                _tag,
                'auto UMP failed ($e) — keeping the gate CLOSED (fail-closed); '
                'this looks like a real consent-fetch failure, not a missing '
                'plugin, so ads stay blocked until the reconnect retry '
                'succeeds');
          }
        });
      }

      // Pick adapter, wire its event sink, then initialise. The resolved
      // GAID is forwarded so the AppLovin adapter can register this device
      // as a test device in debug builds (preserves 1.x policy compliance).
      final adapter = debugAdapterFactory != null
          ? debugAdapterFactory!(config)
          : (config.isAdMob ? AdMobAdapter() : AppLovinAdapter());
      adapter.eventSink = _emit;
      // Same gate loadAppOpenAd()/loadInterstitial()/loadRewardedAd() consult
      // below — adapters that auto-reload from an internal dismiss/fail
      // callback (bypassing those methods entirely) must check this first.
      adapter.canReload = () =>
          !_isVipMember &&
          !AdSafetyConfig.dailyCapReached() &&
          canRequestAds &&
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
              // MJ1 — hand the adapter the full consent state so it can apply
              // the flags its own SDK wants set before native init, instead of
              // waiting for applyToProviders() further down.
              consent: consentMgr.adConsent,
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        SafeLogger.e(_tag, 'adapter init TIMED OUT after 20s');
        ok = false;
      }
      if (!ok) {
        SafeLogger.e(_tag, 'adapter init FAILED');
        // MJ19 — release the adapter we just built. AppLovinAdapter wires its
        // four native listeners BEFORE awaiting the SDK init, so on the 20 s
        // timeout branch the native side can still come up afterwards and
        // those listeners keep firing into slots this manager has already
        // abandoned. With up to 4 attempts that meant up to 4 orphaned
        // adapters, each holding ~15 live ValueNotifiers. dispose() is
        // documented as safe to call before/after initialize, but a
        // half-initialised SDK is exactly where it might throw, so it cannot
        // be allowed to mask the init failure.
        //
        // Disposes the LOCAL `adapter`, not `_adapter`: the field is only
        // assigned further down, once init has succeeded, so on this branch it
        // still holds whatever the previous session left (usually null) and
        // must not be touched.
        try {
          await adapter.dispose();
        } catch (e) {
          SafeLogger.w(_tag, 'disposing the failed adapter threw: $e');
        }
        // Only report the terminal outcome to the host — `onComplete` is a
        // 1.x callback contract meant to fire exactly once per host call.
        // Firing it on every internal retry attempt (up to 4x: the first
        // failure + 3 retries) would surprise hosts expecting a single
        // success/failure signal.
        if (!_scheduleInitRetryIfNeeded(config, onComplete, isRelease)) {
          onComplete(false, _currentDeviceGAID);
          SimpleEventBus().fire(const BoolEvent(false));
        }
        return;
      }

      _initRetryAttempts = 0;
      _initRetryTimer?.cancel();
      _initRetryTimer = null;

      _config = config;
      // M2 — survives `_disposeAdapter()` (which nulls `_config`) so the COPPA
      // recovery in setConsent() can still rebuild the adapter after a re-init
      // that legitimately aborted. Never cleared except by destroy().
      _lastKnownConfig = config;
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
      // B-1 (second independent review) — this is the FIRST push of consent
      // down to the adapter, and it happens before the listener that maintains
      // `_lastAppliedConsent` is attached. Leaving it unseeded here is why the
      // withdrawal guard stayed dead for the two commonest paths: a host that
      // grants consent before initialize() (the order this SDK's own docs
      // recommend), and a returning user whose consent was already persisted.
      // Proven by probe: both read `_lastAppliedConsent == null`.
      _lastAppliedConsent = consentMgr.adConsent;
      _adapter?.applyConsent(consentMgr.adConsent);

      // Consent-coverage footgun (runtime, not config-static so it doesn't
      // false-alarm hosts that gather consent in their splash) — see
      // [consentFootgunWarning].
      final consentWarning = consentFootgunWarning(config,
          // m6 — an auto flow that has started but not yet completed still
          // counts as consent coverage.
          umpRequested: _umpRequested || _umpFlowStarted,
          consentExplicitlySet: _consentExplicitlySet);
      if (consentWarning != null) {
        SafeLogger.w(_tag, consentWarning);
        // N2 — `assert()` below is stripped in release, so without this the
        // gap was silent in production (log-only, ads still served with NO
        // consent form ever shown to EEA/UK users). Hard-block ad requests
        // in release until the host resolves consent — via
        // requestUmpConsent(), a direct setConsent() call from their own
        // consent UI (both clear [_footgunBlocked], see [setConsent]), or by
        // fixing the config footgun itself.
        _applyConsentFootgunGuard(isRelease);
        // F4 — surface this loudly in dev/test builds (stripped in release);
        // the log above is easy to miss.
        assert(false, consentWarning);
      }

      // 2026-08-19 audit (Finding 7) — see [attOrderFootgunWarning]. Not
      // release-blocked like the consent footgun above: this is a
      // revenue/attribution risk, not a legal-compliance one.
      final attWarning = attOrderFootgunWarning(
          attRequested: _attRequested, isIos: Platform.isIOS);
      if (attWarning != null) {
        SafeLogger.w(_tag, attWarning);
        assert(false, attWarning);
      }

      onComplete(true, _currentDeviceGAID);
      SimpleEventBus().fire(const BoolEvent(true));

      SafeLogger.d(_tag, 'triggering App Open + banner/mrec preload');
      unawaited(loadAppOpenAd());
      // Banner/mrec preload also respects VIP — preloading while VIP is
      // active wastes a network request, and on AppLovin it inflates the
      // internal `recordBannerImpression` counter (the widget itself does
      // suppress *display*, but the cache fill is unnecessary).
      if (_isVipMember) {
        SafeLogger.d(_tag, '⏭️ banner/mrec preload skipped — VIP member');
      } else {
        // T65 (phase 2) — no widget exists yet at this call site, so this
        // proactive warm-up uses the shared sentinel key (see its doc
        // comment for the accepted trade-off vs a real widget's own key).
        unawaited(adapter.preloadBanner(_globalBannerWarmupKey));
        unawaited(adapter.preloadMrec(_globalMrecWarmupKey));
      }

      _scheduleFirstSecondaryLoad();
      _startAdRetryTimer();
      unawaited(_startConnectivityWatch());
    } catch (e, st) {
      SafeLogger.e(_tag, 'initialize THREW: $e\n$st');
      if (!_scheduleInitRetryIfNeeded(config, onComplete, isRelease)) {
        onComplete(false, _currentDeviceGAID);
        SimpleEventBus().fire(const BoolEvent(false));
      }
    } finally {
      _isInitializing = false;
    }
  }

  /// Schedules a bounded, backed-off retry of [initialize] after a failed
  /// attempt (adapter init failure or a thrown exception). Caps at
  /// [_maxInitRetryAttempts] so a persistently broken host config (bad ad
  /// unit ids, missing native config) doesn't retry forever — it just waits
  /// for the next app launch or an explicit host-initiated `initialize()`
  /// call, same as before this fix existed. Returns whether a retry was
  /// actually scheduled — callers use this to decide whether *they* still
  /// need to report the failure to `onComplete` themselves (terminal
  /// outcome) or leave it to the retry (non-terminal).
  bool _scheduleInitRetryIfNeeded(
    AdConfig config,
    void Function(bool success, String gaid) onComplete,
    bool isRelease,
  ) {
    if (_initRetryAttempts >= _maxInitRetryAttempts) {
      SafeLogger.w(_tag,
          'adapter init failed $_initRetryAttempts time(s) in a row — giving up auto-retry for this session');
      return false;
    }
    final delay = _initRetryDelays[_initRetryAttempts];
    _initRetryAttempts++;
    SafeLogger.d(
        _tag,
        () =>
            '⏲️ scheduling init retry #$_initRetryAttempts in ${delay.inSeconds}s');
    _initRetryTimer?.cancel();
    _initRetryTimer = Timer(delay, () {
      _isInternalInitRetryCall = true;
      unawaited(initialize(
          config: config, onComplete: onComplete, isRelease: isRelease));
    });
    return true;
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
    // T65 (phase 2) — no widget key at this call site; shares the sentinel
    // key (see its doc comment).
    unawaited(ad.preloadBanner(_globalBannerWarmupKey));
    unawaited(ad.preloadMrec(_globalMrecWarmupKey));
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
    // Round-13 QC (round 2), MAJOR — a host's own consent decision (parental
    // toggle, CCPA switch) is newer than any consent apply still in flight, so
    // it invalidates it. `_inConsentApply` keeps an apply from invalidating
    // itself through its own write.
    if (Zone.current[_consentApplyZoneKey] != true) {
      _consentIntentEpoch++;
      _pendingConsentApply = null;
      _lastHostConsentIntent = consent;
    }
    // MJ7 — capture this BEFORE the assignment below: the AppLovin COPPA check
    // further down needs the value the provider was actually initialised with,
    // and `_consent` is overwritten on the next line.
    final previousAgeRestricted = _consent.isAgeRestrictedUser;
    _consent = consent;
    // N2 — an explicit setConsent() call IS a resolved consent flow (the
    // host's own custom UI, or requestUmpConsent()'s own call into here) —
    // clear the footgun block so a host that doesn't use requestUmpConsent()
    // isn't stuck locked out in release. Deliberately does NOT touch
    // `_canRequestAds` — that field's true/false is owned by the actual UMP
    // result and must not be stomped by this generic reopen.
    final wasFootgunBlocked = _footgunBlocked;
    _consentExplicitlySet = true;
    _footgunBlocked = false;
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
    // R10-B — AppLovin MAX 4.x has no runtime setIsAgeRestrictedUser API.
    // When host flips isAgeRestrictedUser=true mid-session after AppLovin already initialised,
    // we cannot forward the signal, so hard-stop ad requests instead.
    //
    // MJ7 (round 5 audit) — that hard stop was one-way. A host correcting the
    // flag back to false (the user fixed a mistyped birth date) left every
    // AppLovin surface dead for the rest of the process, with no route back
    // short of destroy() + initialize() and nothing in the log saying why.
    // Re-initialising is the only real fix: the flag is only readable by MAX
    // at SDK init, so the adapter has to be rebuilt to carry the new value in
    // either direction. Cheap because `initialize()` already handles the
    // re-init-without-destroy path (it disposes the old adapter, stops the
    // timers and resets guard state).
    final cfg = _config ?? _lastKnownConfig;
    // `_adapter` is deliberately NOT required here: after a child-directed
    // abort there IS no adapter, and rebuilding one is the whole point.
    if (!isAdMobProvider &&
        cfg != null &&
        consent.isAgeRestrictedUser != previousAgeRestricted) {
      SafeLogger.w(
          _tag,
          '🔄 COPPA child-directed flipped to ${consent.isAgeRestrictedUser} '
          'on AppLovin — MAX only reads this at SDK init, so re-initialising '
          'the adapter to carry it');
      if (consent.isAgeRestrictedUser) {
        // Close the gate first: nothing may request an ad between here and the
        // re-init completing.
        _updateCanRequestAds(false);
      }
      await applyConsentToProviders(consent, config: cfg);
      // No infinite-recursion risk: initialize() reaches consent through
      // `_consentManager.set(...)`, not through this method, and the one
      // setConsent() call it does trigger (via auto-UMP) carries the child
      // flag through unchanged — so it cannot re-enter this branch.
      //
      // It CAN be a no-op though: initialize() early-returns while another
      // init is in flight. Say so rather than leaving it silent — a host that
      // flips this flag mid-init would otherwise be left wondering why
      // AppLovin never picked it up.
      if (_isInitializing) {
        SafeLogger.w(
            _tag,
            '⚠️ COPPA flag changed while initialize() is still running — the '
            'AppLovin re-init cannot run now. Call initialize() again once it '
            'completes, or set the flag before initialize().');
      } else {
        unawaited(initialize(config: cfg, onComplete: (_, __) {}));
      }
      return;
    }
    // M2 (independent review) — this early return used to sit ABOVE the COPPA
    // block, which made the recovery that block exists for unreachable. Trace:
    // flag→true re-inits, AppLovinAdapter.initialize() aborts by design for a
    // child-directed audience, so `initialize()` leaves `_adapter`/`_config`
    // null and `isInitialised` false — and the host's later flag→false call
    // then returned here, before the block that would have rebuilt the
    // adapter. AppLovin stayed dead for the session, which is exactly the bug
    // MJ7 was written to fix. The COPPA branch above therefore runs first; it
    // has its own `_adapter != null && cfg != null` guard, so it is a no-op
    // pre-init anyway.
    if (!isInitialised) {
      SafeLogger.d(_tag,
          '⏭️ setConsent: SDK not initialised — buffering for next initialize()');
      return;
    }
    if (!isAdMobProvider && consent.isAgeRestrictedUser) {
      SafeLogger.d(
          _tag, '🛑 COPPA child-directed on AppLovin → hard-stop ad requests');
      _updateCanRequestAds(false);
    }
    await applyConsentToProviders(consent, config: _config);
    // Keep the adapter's per-request personalization (AdMob npa) in sync.
    _adapter?.applyConsent(consent);
    // N2 — the footgun block just cleared and ads may already be running;
    // refill slots that were held back while it was blocked.
    if (wasFootgunBlocked && canRequestAds && !_isVipMember) {
      SafeLogger.d(
          _tag, '🔓 consent footgun resolved → refilling held ad slots');
      _retryRefillAds();
    }
  }

  /// Listener bound to [ConsentManager.listenable]; pushes the latest consent
  /// into the provider adapter so AdMob's per-request `npa` flag tracks every
  /// consent change (dialog answer, set/reset, privacy screen).
  void _syncConsentToAdapter() {
    // MJ5 (round 5 audit) — `_consent` and `_consentManager` were two
    // independent sources of truth for the same thing. `_consent` was only
    // written by setConsent()/initialize(), never by the public
    // `ConsentManager.set()`/`reset()`, so a host that set `doNotSell: true`
    // through ConsentManager had it silently reverted the next time anything
    // rebuilt an AdConsent from `_consent` — a UMP backstop retry, or
    // showPrivacyOptions(). That path wrote doNotSell=false back to disk, to
    // AdMob's `rdp` extra and to AppLovin's setDoNotSell: a CCPA opt-out
    // dropped without a trace. This listener already fires on every consent
    // change from every route, so adopting the value here fixes every reader
    // of `_consent` at once rather than the two call sites the audit found.
    final latest = _consentManager?.adConsent;
    // B1 (independent review of round 5) — this used to compare against
    // `_consent`, which is WRONG and made the whole MJ6 fix dead code:
    // `setConsent()` assigns `_consent = consent` and only then calls
    // `ConsentManager.set()`, whose `ValueNotifier` notifies this listener
    // SYNCHRONOUSLY — so by the time we get here `_consent` already holds the
    // new value and `_consent.hasUserConsent != latest.hasUserConsent` can
    // never be true. Every withdrawal path (showPrivacyOptions(),
    // requestUmpConsent(), a host's own setConsent) goes through exactly that
    // sequence, so cached personalised ads were never discarded. Comparing
    // against what was last actually APPLIED to the adapter is independent of
    // who assigns what in which order.
    // B1 (round-6 audit) — this tracked only ONE of the three axes a consent
    // state can tighten along. A CCPA opt-out (`doNotSell` false→true) and a
    // COPPA flag turned on (`isAgeRestrictedUser` false→true) both left the
    // cache alone, so ads requested under the looser consent kept playing and
    // mounted inline ads kept auto-refreshing the pre-opt-out instance. COPPA
    // is the stricter of the axes and had the weaker protection.
    //
    // Each axis tests a TIGHTENING transition, not merely a change: loosening
    // must not throw away good ads.
    final previous = _lastAppliedConsent;
    final downgraded = latest != null &&
        previous != null &&
        ((previous.hasUserConsent && !latest.hasUserConsent) ||
            (!previous.doNotSell && latest.doNotSell) ||
            (!previous.isAgeRestrictedUser && latest.isAgeRestrictedUser));
    if (latest != null) _consent = latest;
    _lastAppliedConsent = latest ?? _consent;
    _adapter?.applyConsent(latest ?? _consent);

    // MJ6 — applyConsent above only changes what FUTURE requests carry. Ads
    // already loaded under the old (personalised) consent were still shown,
    // and banners kept auto-refreshing, because ad age was the only thing that
    // could discard them. Withdrawal has to invalidate the cache too.
    if (downgraded) {
      SafeLogger.w(
          _tag,
          '🔒 personalisation withdrawn — discarding cached fullscreen ads '
          'and rebuilding inline ads');
      unawaited(_adapter?.discardCachedFullscreenAds() ?? Future<void>.value());
      // M1 (independent review) — bumping `initRevision` here was a no-op for
      // the ads that actually matter. Every inline widget's initRevision
      // listener only re-inits when `!_allowed.value`, and `_allowed` is set
      // true the moment a banner loads and only ever cleared when
      // `canRequestAds` closes — which withdrawing personalisation does NOT
      // do. On top of that `loadBanner` early-returns while the key is still
      // in `_bannerAdsByKey`. So the personalised banner stayed on screen and
      // kept auto-refreshing. This notifier is a separate signal the widgets
      // treat like the gate closing: drop the instance, then reload.
      personalisationRevision.value = personalisationRevision.value + 1;
    }
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
    bool skipIfAlreadyRequested = false,
  }) {
    // MJ8 — one consent flow at a time. Concurrent callers join the in-flight
    // one rather than presenting a second form; see [_umpInFlight].
    final inFlight = _umpInFlight;
    if (inFlight != null) {
      SafeLogger.d(
          _tag, '⏭️ UMP already in flight — joining the existing request');
      return inFlight;
    }
    late final Future<UmpConsentResult> started;
    started = _requestUmpConsent(
      testMode: testMode,
      debugGeography: debugGeography,
      testIdentifiers: testIdentifiers,
      tagForUnderAgeOfConsent: tagForUnderAgeOfConsent,
      skipIfAlreadyRequested: skipIfAlreadyRequested,
    )
        // M6 (independent review) — the mutex was the ONE thing in this round
        // without a deadline, which turned a transient hang into a permanent
        // one: `_requestUmpConsent` awaits `setConsent` → `_persist()`
        // (SharedPreferences) → `updateRequestConfiguration`, neither of which
        // is bounded, and every later caller then joins a future that can
        // never complete. The gate would stay shut with no self-heal — strictly
        // worse than the BL1 lockout this round set out to fix. The cap is
        // generous: it must sit above the 180 s a real user may spend reading
        // the consent form, plus the 20 s network steps around it.
        .timeout(const Duration(seconds: 240), onTimeout: () {
      SafeLogger.e(
          _tag,
          '⏰ UMP flow exceeded 240s — releasing the in-flight lock so later '
          'calls can retry instead of joining a dead future');
      return _lastUmpResult ??
          const UmpConsentResult(
            canRequestAds: false,
            status: ConsentStatus.unknown,
            error: 'ump flow timed out after 240s',
          );
    }).whenComplete(() {
      // m2 — only clear if this call still owns the lock. `_resetGuardState()`
      // can null it mid-flight (destroy + re-init), and without the identity
      // check this late completion would then clear the NEW session's lock and
      // allow two concurrent flows.
      if (identical(_umpInFlight, started)) _umpInFlight = null;
    });
    _umpInFlight = started;
    return started;
  }

  /// Replays the most recent [requestUmpConsent] params — see [_lastUmpParams].
  Future<UmpConsentResult> _retryUmpConsent() {
    final p = _lastUmpParams;
    if (p == null) return requestUmpConsent();
    return requestUmpConsent(
      testMode: p.testMode,
      debugGeography: p.debugGeography,
      testIdentifiers: p.testIdentifiers,
      tagForUnderAgeOfConsent: p.tagForUnderAgeOfConsent,
    );
  }

  Future<UmpConsentResult> _requestUmpConsent({
    required bool testMode,
    required DebugGeography? debugGeography,
    required List<String> testIdentifiers,
    required bool tagForUnderAgeOfConsent,
    required bool skipIfAlreadyRequested,
  }) async {
    // C1 — `autoRequestUmpConsent` now defaults to true, so hosts that already
    // call this themselves in their splash would otherwise run the whole UMP
    // round trip twice. The auto path passes skipIfAlreadyRequested:true and
    // bails when the host got there first; an explicit host call never skips,
    // so "re-show the form from a Privacy screen" still works.
    if (skipIfAlreadyRequested && _umpRequested) {
      SafeLogger.d(_tag,
          '⏭️ auto UMP skipped — host already called requestUmpConsent()');
      final cached = _lastUmpResult ??
          const UmpConsentResult(
            canRequestAds: true,
            status: ConsentStatus.unknown,
            error: 'already requested by host',
          );
      // C-skip — reached from initialize()'s auto-UMP block, which already
      // set _canRequestAds = false before calling in here. The full-flow
      // branch below restores it from a fresh result; this early-return skip
      // branch must do the same from the CACHED result, or a host that
      // follows the SDK's own documented pattern (call requestUmpConsent()
      // manually, then initialize()) gets permanently locked out of ads.
      _updateCanRequestAds(cached.canRequestAds);
      return cached;
    }
    // F9 — log-only order check: ATT must run before UMP on iOS (see this
    // method's docstring / [requestAtt]'s docstring), but this was only ever
    // enforced by convention. Warn, don't block — a host that genuinely
    // doesn't want ATT (e.g. no tracking at all) has no reason to call
    // requestAtt() first.
    if (Platform.isIOS && !_attRequested) {
      SafeLogger.w(
          _tag,
          '⚠️ requestUmpConsent() called before requestAtt() on iOS — call '
          'requestAtt() first so IDFA availability is settled before the '
          'first ad request.');
    }

    // MJ3 — remember what this call used so a retry replays it instead of
    // falling back to the defaults. See [_lastUmpParams].
    _lastUmpParams = (
      testMode: testMode,
      debugGeography: debugGeography,
      testIdentifiers: testIdentifiers,
      tagForUnderAgeOfConsent: tagForUnderAgeOfConsent,
    );

    final result = await requestUmpConsentFlow(
      testMode: testMode,
      debugGeography: debugGeography,
      testIdentifiers: testIdentifiers,
      tagForUnderAgeOfConsent: tagForUnderAgeOfConsent,
    );
    await _applyUmpConsentResult(result);
    return result;
  }

  /// Shared tail of a UMP round trip — applies [result] to the gate, the
  /// persisted consent, the refill-on-unblock path, and the retry/abandon
  /// bookkeeping. Used both by a full [_requestUmpConsent] flow and by
  /// [_recheckAbandonedUmpForm]'s form-less recheck, so the two can never
  /// drift apart on what "applying a UMP result" means.
  ///
  /// [cameFromAbandonedFormRecheck] changes only how [_umpFormAbandoned] is
  /// updated — see that flag's own doc comment and [_recheckAbandonedUmpForm].
  Future<void> _applyUmpConsentResult(
    UmpConsentResult result, {
    bool cameFromAbandonedFormRecheck = false,
  }) async {
    // T01 — the compliance gate. Google policy: do NOT request ads when
    // canRequestAds is false (EEA user who hasn't granted a basis). Every
    // load*() consults [_canRequestAds].
    _umpRequested = true;
    final wasBlocked = !_canRequestAds;
    _updateCanRequestAds(result.canRequestAds);
    SafeLogger.d(
        _tag,
        () =>
            '🔐 UMP gate → canRequestAds=$_canRequestAds (status=${result.status.name})');

    // Map UMP status → AdConsent.hasUserConsent. `required` (form not shown /
    // dismissed without choosing) and `unknown` stay non-personalized.
    //
    // Round-6 audit, BLOCKER — `obtained`/`notRequired` used to be taken as
    // consent on their own. `obtained` means only that the form was COMPLETED:
    // an EEA user who rejected every purpose reaches exactly this branch, and
    // `canRequestAds` stays true because non-personalised ads are still
    // servable. The SDK then told AppLovin `setHasUserConsent(true)` and AdMob
    // `nonPersonalizedAds=false` — serving personalised ads to someone who had
    // just said no, with their own form submission as the evidence.
    //
    // So the real intent is read back from the TCF purpose bitfield the CMP
    // wrote. `null` means there is no TCF signal at all (the normal case
    // outside the EEA, where the UMP status IS the whole answer), so it falls
    // back to the old mapping rather than downgrading every non-EEA user.
    final statusAllows = _umpStatusAllowsPersonalisation(result.status);
    final tcfAllows = await IabStorage.tcfAllowsPersonalisedAds();
    final hasConsent = statusAllows && (tcfAllows ?? true);
    if (statusAllows && tcfAllows == false) {
      SafeLogger.w(
          _tag,
          'UMP status=${result.status.name} but the TCF purpose consents do '
          'NOT permit personalisation → serving non-personalised ads');
    }
    // C2 — only write the mapping when the flow actually completed. On a failed
    // attempt (no network, or the 20s timeout) UMP reports `unknown`, which
    // maps to hasUserConsent=false and would OVERWRITE a choice the user
    // already made in an earlier session: someone who consented, then opened
    // the app with no network, would silently be downgraded to
    // non-personalized ads. Leaving the persisted value alone is both the
    // correct read of "we could not ask" and the conservative one, since the
    // canRequestAds gate is set from UMP's own cached value either way.
    //
    // This was latent before autoRequestUmpConsent defaulted to true; now every
    // host reaches it on a bad network.
    // `unknown` means UMP could not determine anything — NOT that the user
    // refused. Mapping it to hasUserConsent=false overwrote a choice the user
    // had already made and persisted: the log reads
    //   ConsentManager load → consent=true
    //   UmpConsent done status=unknown
    //   ConsentManager set  → consent=false
    // i.e. a silent downgrade to non-personalized ads on every launch where
    // UMP has no information. `required` is different and still maps to false:
    // there the form is genuinely needed and was not completed.
    final umpInconclusive =
        result.error != null || result.status == ConsentStatus.unknown;
    if (!umpInconclusive) {
      // MJ5 — carry the CCPA/COPPA flags over from whichever source is
      // freshest. UMP only ever decides `hasUserConsent`; rebuilding the other
      // two from a stale `_consent` is how a doNotSell opt-out got dropped.
      final current = _consentManager?.adConsent ?? _consent;
      await setConsent(AdConsent(
        hasUserConsent: hasConsent,
        isAgeRestrictedUser: current.isAgeRestrictedUser,
        doNotSell: current.doNotSell,
      ));
    } else {
      SafeLogger.w(
          _tag,
          'UMP inconclusive (status=${result.status.name}, err=${result.error}) '
          '— keeping the persisted consent value instead of downgrading it');
    }

    // If the gate just opened (blocked → allowed) and we're already running,
    // refill the slots that were held back while consent was pending.
    if (wasBlocked && _canRequestAds && isInitialised && !_isVipMember) {
      SafeLogger.d(_tag, '🔓 consent granted → refilling held ad slots');
      _retryRefillAds();
    }
    _lastUmpResult = result;
    // C2 — remember a failed attempt so a later offline->online transition can
    // retry it. `error != null` covers both a network failure and the timeout
    // inside requestUmpConsentFlow.
    //
    // BL1 (round 5 audit) — `error != null` alone was not enough. When UMP
    // resolves from cache without being able to serve a form (a flaky first
    // launch in the EEA), requestUmpConsentFlow returns error == null with
    // canRequestAds == false. Both retry paths gate on this flag, so that
    // combination wedged the gate shut for the entire session: zero ads, and
    // no way back short of an app restart even once the network returned.
    // Reuses `umpInconclusive` from above so the retry decision and the
    // consent-value decision cannot drift apart again.
    _umpAttemptFailed =
        result.error != null || umpInconclusive || !result.canRequestAds;
    if (cameFromAbandonedFormRecheck) {
      // M-3 (independent review) — `!umpInconclusive` is the WRONG condition
      // here: a still-unanswered form reads back status=required, which is
      // conclusive (no error, not `unknown`) but not resolved. Clearing on
      // that would let the very next backstop tick call the full flow and
      // present a SECOND form on top of the one still on screen — the exact
      // bug this flag exists to prevent. Only `required` means "still
      // pending"; obtained/notRequired (and even a fresh `unknown`) all mean
      // the abandoned form is no longer the open question.
      if (result.status != ConsentStatus.required) _umpFormAbandoned = false;
    } else {
      // Assigned (not just set) so a later flow that completes normally
      // clears it — otherwise one timeout would mute the backstop forever.
      _umpFormAbandoned =
          result.formShown && (result.error?.contains('timed out') ?? false);
      if (_umpFormAbandoned) {
        SafeLogger.w(
            _tag,
            '⚠️ consent form abandoned by our own timeout — the native form '
            'may still be on screen, so the periodic backstop will not '
            're-present one');
      }
    }
  }

  /// M-3 (independent review) — recovers from [_umpFormAbandoned] without
  /// risking a second native form on top of one that may still be on
  /// screen. `Future.timeout` cannot close a native dialog, so once our own
  /// dismiss timeout fires, calling the full UMP flow again (which may
  /// present a form) is unsafe; but muting the backstop forever — the
  /// previous behaviour — meant a user who answered the still-open form 10
  /// seconds after our timeout lost every ad for the rest of the session.
  /// This only reads what Google's SDK already knows locally (no form, no
  /// network round trip), so it is always safe to call on every tick.
  Future<void> _recheckAbandonedUmpForm() async {
    final result = await recheckUmpConsentStatus();
    SafeLogger.d(
        _tag,
        () => '🔁 rechecking abandoned UMP form (no form presented) → '
            'status=${result.status.name} canRequestAds=${result.canRequestAds}');
    await _applyUmpConsentResult(result, cameFromAbandonedFormRecheck: true);
  }

  /// Whether UMP already got an answer out of this user, or decided none was
  /// needed. `obtained` covers **both** accept and reject.
  ///
  /// m11 (round 5 audit) — the BL1 fix above widened [_umpAttemptFailed] to
  /// include "gate still closed", which is also the state of an EEA user who
  /// legitimately chose to reject. Without this check the retry paths would
  /// re-run the consent flow every 5 minutes for the rest of the session,
  /// re-presenting a form that user has already answered.
  bool get _umpAnswered {
    final s = _lastUmpResult?.status;
    return s == ConsentStatus.obtained || s == ConsentStatus.notRequired;
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
    // Round-13 (device verification) BLOCKER — the flow's own wait frees this
    // call while the native form is still up, and the status it returns is
    // therefore read BEFORE the user has chosen. `onLateDismiss` re-runs the
    // apply step with what they actually chose; without it a withdrawal made
    // after the wait expired never reached either provider.
    // Round-13 QC (round 7) — bind the form to this session, so a dismiss
    // that arrives after a `destroy()` cannot write a dead session's answer
    // over the live one's.
    final session = _consentSessionEpoch;
    final result = await requestPrivacyOptionsFlow(
      onLateDismiss: (late) => unawaited(
          _applyPrivacyOptionsResult(late, session: session)
              .catchError((Object e) {
        // The apply is async all the way down (storage, both providers), so
        // without this a failure in it becomes an unhandled zone error rather
        // than a logged one — nothing is awaiting this future.
        SafeLogger.e(_tag, 'late privacy-options apply threw: $e');
        return late;
      })),
    );
    // Round-13 QC — the at-timeout snapshot is INCONCLUSIVE by construction:
    // the form is still on screen, so this status predates the user's choice.
    // Applying it was two bugs in one — it could fire `_retryRefillAds()`
    // while the user was still reading, and it raced the late apply, so the
    // stale value could land last and overwrite the real answer. Same guard
    // as `umpInconclusive` in [_applyUmpConsentResult]; `onLateDismiss` above
    // is what carries the answer once there is one.
    if (result.formShown && (result.error?.contains('timed out') ?? false)) {
      SafeLogger.w(
          _tag,
          'privacy options: our wait expired with the form still on screen — '
          'keeping the current consent until the form reports back');
      return result;
    }
    return _applyPrivacyOptionsResult(result, session: session);
  }

  /// The newest consent intent waiting to be written, and whether a write is
  /// already in flight.
  ///
  /// Round-13 QC (round 2), MAJOR — a generation counter was not enough: it
  /// only covered the *read* phase, so an older apply that had already passed
  /// the check could still finish its `setConsent` write last and restore the
  /// stale value. Two applies therefore never overlap at all now — the one in
  /// flight picks up whatever newer intent arrived and writes that too, so the
  /// last write is always the newest intent.
  ///
  /// Deliberately not an instance-level future chain: a queued tail future in
  /// a dead zone is what wedged the whole test suite in round 12 (see
  /// `doc/audit/audit_round8_10.md`). Nothing here awaits anyone else's
  /// future — a second caller just parks its intent and returns.
  PrivacyOptionsResult? _pendingConsentApply;
  bool _consentApplyRunning = false;

  /// Identifies the run that currently owns [_consentApplyRunning], so a loop
  /// that has been disowned (by [destroy]) cannot release the flag out from
  /// under the loop that replaced it.
  ///
  /// Round-13 QC (round 5), MAJOR — [destroy] clears the flag while the old
  /// loop is still alive, so that loop's `finally` used to hand the runner
  /// away while a *new* run held it. Two loops then wrote concurrently and an
  /// older consent decision could land after a newer one.
  int _consentApplyRunToken = 0;

  /// Bumped whenever something *outside* a consent apply changes the consent
  /// intent — a host calling [setConsent] directly, or [destroy] tearing the
  /// session down. An in-flight apply that sees this move drops itself instead
  /// of overwriting a decision that was made after it started.
  int _consentIntentEpoch = 0;

  /// Bumped by [destroy] only. A privacy-options form opened by a session that
  /// has since been torn down must not have its answer applied into the
  /// session that replaced it.
  ///
  /// Round-13 QC (round 7), MAJOR — [_consentIntentEpoch] cannot carry this:
  /// it is also bumped by a host [setConsent], and dropping a late withdrawal
  /// because the host set something mid-form would lose the very decision
  /// this whole path exists to deliver. Session identity has to be its own
  /// counter.
  int _consentSessionEpoch = 0;

  /// Marks the async context of a consent write made *by* an apply, so that
  /// write does not invalidate the apply that issued it.
  ///
  /// Round-13 QC (round 3), MAJOR — this used to be a plain boolean held
  /// across the awaited write, which meant a host calling [setConsent] during
  /// that window was mistaken for the apply's own write and silently lost its
  /// epoch bump. A zone value is scoped to one async context instead of to
  /// wall-clock time, so a host call from anywhere else is never confused with
  /// it.
  static const Object _consentApplyZoneKey = #adSdkConsentApply;

  /// The last consent a host (or [requestUmpConsent]) asked for, kept so an
  /// apply that finds itself superseded mid-write can put it back. Null after
  /// [destroy], so a dead session never gets one re-applied into it.
  AdConsent? _lastHostConsentIntent;

  Future<void> _writeConsentFromApply(AdConsent consent) =>
      runZoned(() => setConsent(consent),
          zoneValues: <Object, Object>{_consentApplyZoneKey: true});

  /// Map a [PrivacyOptionsResult] onto both providers. Split out of
  /// [showPrivacyOptions] so the late-dismiss callback and the resume
  /// re-check can reuse it verbatim.
  Future<PrivacyOptionsResult> _applyPrivacyOptionsResult(
      PrivacyOptionsResult result,
      {int? session}) async {
    if (session != null && session != _consentSessionEpoch) {
      // Round-13 QC (round 8), BLOCKER — `destroy()` does not dismiss the
      // native form, so this callback may be carrying a real withdrawal the
      // user made while the live session was already running. Its *values*
      // belong to a dead session and must not be written, but the choice
      // itself is on the device (the CMP wrote it to the IAB TCF keys), so
      // re-read that instead of simply dropping it. Tighten-only, like the
      // resume backstop.
      SafeLogger.w(
          _tag,
          'a privacy-options form from a torn-down session reported back '
          '(session=$session, now=$_consentSessionEpoch) — dropping its values '
          'and re-reading the device consent state instead');
      await _recheckConsentOnResume();
      return result;
    }
    // Round-13 QC (round 9), MAJOR — a restrictive intent tightens the gate the
    // moment it is queued. Waiting for the runner to reach it left a window in
    // which the apply already in flight could open the gate for its older,
    // more permissive result — and by then the form is gone, so the caller is
    // free to request an ad.
    if (!result.canRequestAds) _updateCanRequestAds(false);
    _pendingConsentApply = result;
    if (_consentApplyRunning) {
      // A write is already in flight and will pick this up when it finishes.
      // Returning early (rather than awaiting it) is what keeps this free of
      // the round-12 dead-zone trap.
      return result;
    }
    _consentApplyRunning = true;
    final token = ++_consentApplyRunToken;
    try {
      while (_pendingConsentApply != null) {
        final next = _pendingConsentApply!;
        _pendingConsentApply = null;
        await _applyConsentResultOnce(next);
      }
    } finally {
      // Only the current owner may release the runner — see
      // [_consentApplyRunToken].
      if (_consentApplyRunToken == token) _consentApplyRunning = false;
    }
    return result;
  }

  /// Test-only barrier awaited right after an apply captures its epoch, so a
  /// test can hold an apply open and let a newer decision land underneath it.
  /// The race it exposes lives in a window a few microtasks wide, which no
  /// public API can hit reliably.
  @visibleForTesting
  static Future<void>? debugConsentApplyBarrier;

  /// Test-only barrier awaited immediately before the consent write, so a test
  /// can let a host decision land while the write is in flight.
  @visibleForTesting
  static Future<void>? debugConsentWriteBarrier;

  Future<void> _applyConsentResultOnce(PrivacyOptionsResult result) async {
    final epoch = _consentIntentEpoch;
    final barrier = debugConsentApplyBarrier;
    if (barrier != null) await barrier;
    final wasBlocked = !_canRequestAds;

    // Round-6 audit, BLOCKER — same `obtained` != "consented" trap as
    // [_applyUmpConsentResult], and this is the sharper half of it: Privacy
    // Options is *the* withdrawal path. A user who reopens the form
    // specifically to turn personalisation off submits it, gets `obtained`, and
    // used to be handed `hasUserConsent: true` — personalised ads resuming
    // immediately after an explicit withdrawal. See
    // [IabStorage.tcfAllowsPersonalisedAds] for what is read instead.
    final statusAllows = _umpStatusAllowsPersonalisation(result.status);
    final tcfAllows = await IabStorage.tcfAllowsPersonalisedAds();
    final hasConsent = statusAllows && (tcfAllows ?? true);
    if (statusAllows && tcfAllows == false) {
      SafeLogger.w(
          _tag,
          'privacy options completed but the TCF purpose consents do NOT '
          'permit personalisation → serving non-personalised ads');
    }
    // A host `setConsent` (parental toggle, CCPA switch) or a `destroy()` that
    // landed while we were reading storage wins: a late-dismiss callback must
    // never mutate a session that has since been torn down and re-initialised.
    // Deliberately NOT gated on `isInitialised` — a host may legitimately run
    // the consent flow before (or without) an adapter, and the consent still
    // has to be recorded for whenever one arrives.
    if (epoch != _consentIntentEpoch) {
      SafeLogger.w(
          _tag,
          'consent apply superseded while reading the TCF state '
          '(epoch=$epoch, now=$_consentIntentEpoch) — '
          'dropping it so the newer decision wins');
      return;
    }
    // Round-13 QC (round 3), BLOCKER — the ad gate is opened only HERE, after
    // the epoch check. Doing it first (as this used to) let a superseded late
    // callback reopen the gate and then yield on the storage read, so an ad
    // could be requested under a consent a newer host decision or `destroy()`
    // had already invalidated — a transient breach the end-state assertions
    // could not see.
    //
    // Round-13 QC (round 6), MAJOR — and it may only TIGHTEN here. Opening it
    // before the write has landed leaves a window (the provider write plus the
    // storage write) in which an ad can be requested under a consent a newer
    // host decision is about to overwrite. Restrictive now, permissive only
    // once the write has landed under our own epoch — same asymmetry as the
    // resume backstop: a missed grant costs one refill, a fill under a
    // withdrawn consent is a violation.
    //
    // Round-13 QC (round 10), BLOCKER — and `canRequestAds` is the wrong
    // signal to read on its own. The ordinary withdrawal — a user turning
    // personalisation off in the CMP form — leaves `canRequestAds` TRUE
    // (non-personalised ads are still servable) and shows up only in the TCF
    // purposes read above. So the gate stayed open across the provider +
    // storage write while the OLD personalised configuration was still
    // applied, and any load in that window (a banner refresh, a newly mounted
    // ad surface, a host-triggered load) requested a *personalised* ad after
    // an explicit withdrawal. Close it whenever this apply tightens either
    // signal; the post-write branch below is what reopens it.
    final appliedBefore = _consentManager?.adConsent ?? _consent;
    if (!result.canRequestAds ||
        (!hasConsent && appliedBefore.hasUserConsent)) {
      _updateCanRequestAds(false);
    }
    SafeLogger.d(
        _tag,
        () =>
            '🔐 privacy options → canRequestAds=$_canRequestAds (status=${result.status.name})');
    // MJ5 — see requestUmpConsent(): read the freshest CCPA/COPPA flags rather
    // than rebuilding them from a possibly-stale `_consent`.
    final current = _consentManager?.adConsent ?? _consent;
    final writeBarrier = debugConsentWriteBarrier;
    if (writeBarrier != null) await writeBarrier;
    await _writeConsentFromApply(AdConsent(
      hasUserConsent: hasConsent,
      isAgeRestrictedUser: current.isAgeRestrictedUser,
      doNotSell: current.doNotSell,
    ));

    // Round-13 QC (round 3), MAJOR — a host decision that landed *while* the
    // write was in flight is the newer one, and this write may have been the
    // last one to touch storage. Put the host's value back rather than leaving
    // ours standing. `destroy()` clears `_lastHostConsentIntent`, so a
    // teardown does not get a value re-applied into it.
    if (epoch != _consentIntentEpoch) {
      final hostIntent = _lastHostConsentIntent;
      if (hostIntent != null) {
        SafeLogger.w(
            _tag,
            'a host consent decision landed while this apply was writing — '
            'restoring it over ours');
        await _writeConsentFromApply(hostIntent);
      }
      return;
    }
    // The write landed and nothing superseded it — now the gate may open. Not
    // while a newer intent is still queued, though: that one gets to decide.
    if (result.canRequestAds && _pendingConsentApply == null) {
      _updateCanRequestAds(true);
    }
    if (wasBlocked && _canRequestAds && isInitialised && !_isVipMember) {
      SafeLogger.d(_tag,
          '🔓 consent granted via privacy options → refilling held ad slots');
      _retryRefillAds();
    }
  }

  /// Whether a UMP [ConsentStatus] leaves personalisation possible at all.
  /// `required`/`unknown` mean the form was not completed, so no.
  static bool _umpStatusAllowsPersonalisation(ConsentStatus status) =>
      status == ConsentStatus.obtained || status == ConsentStatus.notRequired;

  /// Round-13 (device verification) BLOCKER, backstop half — re-apply consent
  /// on resume when the device disagrees with what is applied.
  ///
  /// A CMP writes the user's choice to the IAB TCF keys the moment they submit
  /// the form, whether or not our dismiss callback ever arrives (a form torn
  /// down by the OS, a plugin that drops the callback, a process resumed after
  /// the form was answered). The late-dismiss path in [showPrivacyOptions]
  /// covers the common case; this covers the ones where no callback comes at
  /// all, so a withdrawal can never survive as personalised ads for a whole
  /// session.
  ///
  /// Cheap: the TCF read is a `SharedPreferences` lookup, and the UMP channel
  /// is only touched when it disagrees with the applied value — i.e. never on
  /// an ordinary resume.
  Future<void> _recheckConsentOnResume() async {
    if (!isInitialised) return;
    final tcfAllows = await IabStorage.tcfAllowsPersonalisedAds();
    // No TCF data at all (the normal non-EEA case) — nothing to compare
    // against, and UMP alone is already the whole answer there.
    if (tcfAllows == null) return;
    final applied = _consentManager?.adConsent ?? _consent;
    if (applied.hasUserConsent == tcfAllows) return;
    // Round-13 QC, MINOR — tighten only, never grant.
    // `tcfAllowsPersonalisedAds` reports true for `gdprApplies=0` (out of
    // scope: the bitfield says nothing), so granting here would flip a host's
    // own deliberate `setConsent(hasUserConsent: false)` — a parental toggle,
    // a CCPA choice — back on at every resume. The two directions are not
    // symmetrical either: a missed withdrawal is a compliance violation, a
    // missed grant costs one session of personalised fill and is what the
    // normal consent paths are for.
    if (tcfAllows) return;

    final ump = await core_ump.recheckUmpConsentStatus();
    final expected = _umpStatusAllowsPersonalisation(ump.status) && tcfAllows;
    if (expected == applied.hasUserConsent) return;

    SafeLogger.w(
        _tag,
        '🔐 resume: device consent state disagrees with what is applied '
        '(TCF personalisation=$tcfAllows, UMP status=${ump.status.name}, '
        'applied hasUserConsent=${applied.hasUserConsent}) — re-applying');
    await _applyPrivacyOptionsResult(PrivacyOptionsResult(
      canRequestAds: ump.canRequestAds,
      status: ump.status,
    ));
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
    _attRequested = true;
    SafeLogger.d(_tag, () => 'ATT → ${result.status.name}');
    // M9 — resolve the GAID fetch initialize() deferred (ATT was still
    // undecided at init time) now that ATT has actually been decided, and
    // re-run the config VIP-GAID whitelist check that depends on it.
    if (_gaidFetchDeferredForAtt) {
      _gaidFetchDeferredForAtt = false;
      await _resolveDeviceGaid();
      final config = _config;
      final vip = _vipManager;
      if (config != null && vip != null) {
        final prefs = await AdPreferences.getInstance();
        await _applyConfigVipGaidWhitelist(config, vip, prefs);
      }
    }
    return result;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  DESTROY — full teardown: disposes the adapter, VIP/arbitrator/fill-rate
  //  managers, timers and the lifecycle observer, then resets in-memory
  //  flags so a later initialize() starts clean.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> destroy() async {
    SafeLogger.d(_tag, 'destroy() called');
    // Round-13 QC (round 2), MAJOR — a privacy-options form can still be on
    // screen with our own wait already expired, so its late-dismiss apply can
    // arrive after this teardown. Bumping the epoch makes that apply drop
    // itself instead of writing a dead session's answer over a new one.
    _consentIntentEpoch++;
    _consentSessionEpoch++;
    _pendingConsentApply = null;
    _lastHostConsentIntent = null;
    // Round-13 QC (round 4), MAJOR — a consent write that is still hanging at
    // teardown must not lock the next session out of applying consent at all.
    // Releasing the flag can leave the old loop running alongside a new one,
    // which is harmless: the epoch bump above makes everything it was carrying
    // drop itself — and the token bump stops it releasing the runner out from
    // under the next session's loop.
    _consentApplyRunToken++;
    _consentApplyRunning = false;
    // M2 — cleared HERE only, never in `_disposeAdapter()`: surviving adapter
    // teardown is precisely what makes the COPPA re-init path in setConsent()
    // reachable after a child-directed abort.
    _lastKnownConfig = null;
    _lastAppliedConsent = null;
    await _eventStream.close();
    _eventStream = StreamController<AdEvent>.broadcast();
    await _disposeAdapter();
    // Bump revision so subscribed widgets rebuild against the now-null adapter
    // (otherwise BannerAdWidget would keep painting the stale provider's view
    // until something else triggers a rebuild).
    initRevision.value = initRevision.value + 1;
    _stopAdRetryTimer();
    _stopConnectivityWatch();
    _initRetryTimer?.cancel();
    _initRetryTimer = null;
    _initRetryAttempts = 0;
    AdLoadingDialog.resetState();
    AdScreenRouteLogger.resetState();
    // Round-7 final QC — the UMP form counter is module-level, so a flow that
    // was interrupted (or a form whose dismiss callback never arrived) would
    // otherwise carry its ad block across this teardown into the next
    // initialize(). Safe to drop here: destroy() has just torn the adapter
    // down, so there is no ad that could be drawn over anything.
    resetUmpFormOnScreen();
    AdSafetyConfig.resetForReinit();
    SimpleEventBus().clearAll();

    _vipManager?.activeListenable.removeListener(_onVipActiveChanged);
    _vipManager?.dispose();
    _vipManager = null;
    _vipReadyNotifier.value = false;

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
    _fillRateBaselineMonitorGen++;
    _fillRateBaselineMonitor?.dispose();
    _fillRateBaselineMonitor = null;

    _isSplashActive = false;
    _countInitSplashScreen = 0;
    _isFirstAdLoadTriggered = false;
    _lastBannerLoadAtByKey.clear();
    // 2026-08-16 audit: mrec/native cooldown maps were missing here — a
    // destroy() + fresh initialize() within the cooldown window (without
    // unmounting the widget) would inconsistently treat MREC/Native as
    // still "on cooldown" while Banner correctly reset.
    _lastMrecLoadAtByKey.clear();
    _lastNativeLoadAtByKey.clear();
    _lastFullscreenDismissAt = 0;
    _rewardedInFlight = false;
    _isInitializing = false;
    _consentDialogScheduled = false;
    _offlineNotifier.value = false;
    _resetGuardState();

    // T70 — same reasoning as vipManager/consentManager/arbitrator above: a
    // stale _eventLog left alive past destroy() would keep being flushed
    // (didChangeAppLifecycleState's paused handler calls flush() whenever
    // _eventLog is non-null) and mix pre-destroy events into whatever
    // provider initialize() brings up next. Flush first so nothing queued
    // in its debounce window is lost.
    unawaited(_eventLog?.flush());
    _eventLog = null;

    if (_isObserverAdded) {
      WidgetsBinding.instance.removeObserver(this);
      _isObserverAdded = false;
    }
    SafeLogger.d(_tag, 'destroy() ✅');
  }

  // R12-A audit round 6: single source of truth for the footgun/consent
  // guard flags — destroy() and initialize()'s reinit-without-destroy()
  // branch used to hand-copy this list independently, which is exactly how
  // _footgunBlocked (Round 5) and _umpRequested/_consentExplicitlySet
  // (Round 6) each went unreset on a re-init in turn. Otherwise a
  // setConsent()/requestUmpConsent() call in one session permanently flips
  // these for every initialize() after this destroy() or reinit.
  //
  // _resumeFallbackTimer/_splashBudgetTimer joined this list for the same
  // reason: they used to be cancelled only inside destroy(), so a re-init
  // via the reinit-without-destroy() branch left a stale timer alive that
  // could later fire markSplashInactive() or an app-open show against the
  // freshly re-initialized adapter.
  void _resetGuardState() {
    _footgunBlocked = false;
    _umpRequested = false;
    _umpFlowStarted = false;
    _umpFormAbandoned = false;
    _consentExplicitlySet = false;
    // T63 — these two silently outlived destroy()/re-init, leaving a host
    // with autoRequestUmpConsent:false no assignment left to ever reopen
    // ad requests (stale `false` reads as "still gated" for the entire new
    // session), and a stale failed-attempt flag from the old session.
    // Restored to their declaration-time defaults (see field docs above).
    _updateCanRequestAds(true);
    _umpAttemptFailed = false;
    _umpBackstopRetryCount = 0;
    // Round 5: these follow the same rule as the two above — a stale in-flight
    // marker would make every later requestUmpConsent() join a future that can
    // never complete, and stale params would be replayed into the new session.
    _umpInFlight = null;
    _lastUmpParams = null;
    _lastUmpResult = null;
    // m5 — `_attRequested` outlived teardown too. A stale `true` makes
    // shouldDeferGaidFetch() believe ATT has already been answered in the new
    // session, so initialize() reads the GAID without waiting for a decision,
    // and attOrderFootgunWarning() stops warning a host that never calls
    // requestAtt(). Both are the exact wrong answers after a reset.
    _attRequested = false;
    _resumeFallbackTimer?.cancel();
    _resumeFallbackTimer = null;
    _splashBudgetTimer?.cancel();
    _splashBudgetTimer = null;
    // Audit fix: a stale GAID from the previous session used to survive
    // destroy()/re-init, so currentDeviceGaid (and adMobTestDeviceHashHint())
    // could report a device's ad ID after the SDK claimed to be torn down —
    // a privacy leak past the point consent should be re-evaluated at.
    if (_currentDeviceGAID.isNotEmpty) {
      SafeLogger.d(_tag, 'resetGuardState: clearing stale GAID');
    }
    _currentDeviceGAID = '';
  }

  /// Test seam for [_resetGuardState] — exercised directly by
  /// ad_manager_core_test.dart since a real reinit-without-destroy() can't
  /// be driven through `initialize()` under `flutter test` (no native
  /// adapter).
  @visibleForTesting
  void debugResetGuardState() => _resetGuardState();

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

  Future<void> loadAppOpenAd(
      {void Function(bool loaded)? onAdLoaded,
      Duration watchdog = const Duration(seconds: 30)}) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — adapter null');
      _emitSkip(AdSlotType.appOpen, 'load', 'adapter_null');
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
      _emitSkip(AdSlotType.appOpen, 'load', 'splash_only_inactive');
      onAdLoaded?.call(false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — VIP member');
      _emitSkip(AdSlotType.appOpen, 'load', 'vip');
      onAdLoaded?.call(false);
      return;
    }
    if (AdSafetyConfig.dailyCapReached()) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — daily cap reached');
      _emitSkip(AdSlotType.appOpen, 'load', 'daily_cap');
      onAdLoaded?.call(false);
      return;
    }
    if (!canRequestAds) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.appOpen, 'load', 'consent');
      onAdLoaded?.call(false);
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — no network');
      _emitSkip(AdSlotType.appOpen, 'load', 'no_network');
      onAdLoaded?.call(false);
      return;
    }
    // Adapter emits AdLoadEvent itself on listener fire — orchestrator only
    // forwards the boolean callback to the caller (avoids double-emit).
    await ad.loadAppOpen(onAdLoaded: onAdLoaded);
    _armLoadWatchdog('appOpen', ad.appOpenSlot, watchdog);
  }

  Future<void> showAppOpenAd({
    required void Function(bool dismissed) onAdDismiss,
    bool bypassSafety = false,
    AdPlacement placement = AdPlacement.splash,
  }) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — adapter null');
      _emitSkip(AdSlotType.appOpen, 'show', 'adapter_null',
          placement: placement);
      onAdDismiss(false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — VIP member');
      _emitSkip(AdSlotType.appOpen, 'show', 'vip', placement: placement);
      onAdDismiss(false);
      return;
    }
    if (bypassSafety && _config?.appOpenTrigger == AppOpenTrigger.resumeOnly) {
      SafeLogger.d(
          _tag, '⏭️ showAppOpen (splash) skipped — appOpenTrigger=resumeOnly');
      _emitSkip(AdSlotType.appOpen, 'show', 'resume_only_trigger',
          placement: placement);
      onAdDismiss(false);
      return;
    }
    // T03 — never show an impression before consent is resolved, even the
    // splash App Open with bypassSafety. The load gate already prevents loading,
    // this closes the window where a previously-loaded ad could show after
    // consent is revoked.
    if (!canRequestAds) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.appOpen, 'show', 'consent', placement: placement);
      onAdDismiss(false);
      return;
    }
    // C3 — this is a direct show* entry point (called from splash and any
    // host that wants an app-open impression outside the resume flow), so it
    // must consult the same shared mutex as showInterstitial/showRewarded
    // rather than only checking its own slot.
    final busyAO = _fullscreenBusyReason;
    if (busyAO != null) {
      SafeLogger.d(_tag, '⏭️ showAppOpen skipped — $busyAO');
      _emitSkip(AdSlotType.appOpen, 'show', 'busy', placement: placement);
      onAdDismiss(false);
      return;
    }
    // Round-6 audit: `bypassSafety` is documented as skipping the FREQUENCY
    // limits so a cold start can always monetise — daily cap, 30s throttle,
    // per-placement cap. The invalid-traffic cooldown lives inside the same
    // `canShowFullscreenAd()` call, so it was being skipped too, and this is
    // the surface that shows most often: a device already flagged for click
    // fraud got an App Open on every single launch. That pause protects the
    // publisher's AdMob account, not the user's pacing, so it applies even
    // here. Checked via the side-effect-free getter so the bypass path cannot
    // record a violation of its own.
    if (AdSafetyConfig.isInvalidTrafficPauseActive) {
      SafeLogger.w(
          _tag,
          '⏭️ showAppOpen skipped — invalid-traffic pause active (bypassSafety '
          'does not cover it)');
      _emitSkip(AdSlotType.appOpen, 'show', 'invalid-traffic-pause',
          placement: placement);
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
      // T92 — additional per-placement daily cap, same bypassSafety
      // exemption as the global cooldown check just above (a host that
      // opted out of ALL safety for this call shouldn't get half-exempted).
      if (AdSafetyConfig.placementDailyCapReached(placement)) {
        SafeLogger.d(_tag,
            '⏭️ showAppOpen skipped — placement daily cap reached ($placement)');
        _emitSkip(AdSlotType.appOpen, 'show', 'placement_cap',
            placement: placement);
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
        AdSafetyConfig.recordPlacementAdShown(placement); // T92
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
    // Round-7 audit, MAJOR — the latch has to be spent by THIS resume even if
    // one of the guards below returns first. It used to be read at its decision
    // point, six early returns down (adapter null, splashOnly, splash active,
    // VIP, another fullscreen/dialog on top): a click followed by a resume that
    // hit any of those left the latch set, and it then suppressed the next
    // genuine background→foreground App Open — a lost impression attributed to
    // an ad click the user made hours earlier. The latch answers "was the
    // resume I am handling now a return trip from an ad click?", so it is read
    // once per resume and the verdict carried in a local.
    final returningFromAdClick =
        AdSafetyConfig.consumeBackgroundedFromAdClick();
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
    // C3 — same shared mutex the other two show paths now use. This path
    // already had the full condition inline; it is the one the helper was
    // extracted from. Covers stacking on another fullscreen ad AND on a modal
    // (consent dialog, VIP confirmation, the SDK's own loading buffer) — an ad
    // over a dialog is bad UX and an AdMob policy risk.
    final busyAO = _fullscreenBusyReason;
    if (busyAO != null) {
      SafeLogger.d(_tag, '⏭️ app-open on resume skipped — $busyAO');
      return;
    }

    // Guard window widened from 2 s → 5 s. Real-world fullscreen dismiss →
    // resume can stretch past 2 s on slower devices, and the slot-state
    // watcher gives us an accurate dismiss instant — so suppressing app-open
    // for 5 s after any fullscreen ad covers the bounce-back UX without
    // starving legitimate background→foreground app-open impressions.
    // M1 — the user left because they tapped an ad, so this resume is the
    // return trip from the landing page, not a fresh app entry. Google's App
    // Open policy calls this case out by name. Placed with the other
    // attribution guards, i.e. ahead of the cold-start skip, so it returns
    // without kicking off a refill.
    if (returningFromAdClick) {
      SafeLogger.d(
          _tag,
          () => '⏭️ skipping app-open on resume '
              '(user is returning from an ad click)');
      _emitSkip(AdSlotType.appOpen, 'show', 'returning-from-ad-click');
      return;
    }
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
          // 2026-08-19 audit (Finding 4/6): this used to be bypassSafety:
          // true, letting a resume-triggered App Open skip the daily/
          // hourly/session cap entirely while still counting toward it via
          // recordFullscreenAdShown() below — an asymmetric bypass outside
          // the one case (splash) this repo's own contract allows. The
          // resume-specific timing gates (canShowAppOpenOnResume above)
          // still apply either way; this only restores the shared cap.
          bypassSafety: false,
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
          // 2026-08-19 audit (Finding 4/6): this used to be bypassSafety:
          // true, letting a resume-triggered App Open skip the daily/
          // hourly/session cap entirely while still counting toward it via
          // recordFullscreenAdShown() below — an asymmetric bypass outside
          // the one case (splash) this repo's own contract allows. The
          // resume-specific timing gates (canShowAppOpenOnResume above)
          // still apply either way; this only restores the shared cap.
          bypassSafety: false,
          onAdDismiss: (_) => unawaited(loadAppOpenAd()),
        ));
      });
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  INTERSTITIAL — load/show/canShow, mirroring the App Open gates (VIP,
  //  consent, safety) plus the optional arbitrator nudge-to-VIP veto.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadInterstitial(
      {Duration watchdog = const Duration(seconds: 30)}) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — adapter null');
      _emitSkip(AdSlotType.interstitial, 'load', 'adapter_null');
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — VIP member');
      _emitSkip(AdSlotType.interstitial, 'load', 'vip');
      return;
    }
    if (AdSafetyConfig.dailyCapReached()) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — daily cap reached');
      _emitSkip(AdSlotType.interstitial, 'load', 'daily_cap');
      return;
    }
    if (!canRequestAds) {
      SafeLogger.d(
          _tag, '⏭️ loadInterstitial skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.interstitial, 'load', 'consent');
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, '⏭️ loadInterstitial skipped — no network');
      _emitSkip(AdSlotType.interstitial, 'load', 'no_network');
      return;
    }
    await ad.loadInterstitial();
    _armLoadWatchdog('interstitial', ad.interstitialSlot, watchdog);
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
      _emitSkip(AdSlotType.interstitial, 'show', 'adapter_null',
          placement: placement);
      onDoneFlow(false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ showInterstitial skipped — VIP member');
      _emitSkip(AdSlotType.interstitial, 'show', 'vip', placement: placement);
      onDoneFlow(false);
      return;
    }
    if (!canRequestAds) {
      SafeLogger.d(
          _tag, '⏭️ showInterstitial skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.interstitial, 'show', 'consent',
          placement: placement);
      onDoneFlow(false);
      return;
    }
    // C3 — one shared mutex, not just "am I already showing". Before this,
    // an interstitial could open on top of a rewarded ad or an App Open.
    final busyI = _fullscreenBusyReason;
    if (busyI != null) {
      SafeLogger.d(_tag, '⏭️ showInterstitial skipped — $busyI');
      _emitSkip(AdSlotType.interstitial, 'show', 'busy', placement: placement);
      onDoneFlow(false);
      return;
    }
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) {
      SafeLogger.d(_tag,
          () => '⏭️ showInterstitial blocked by safety: ${safety.reason}');
      _emitSkip(AdSlotType.interstitial, 'show', 'cooldown',
          placement: placement);
      onDoneFlow(false);
      return;
    }
    // T92 — additional per-placement daily cap, on top of (never instead
    // of) the global one just above.
    if (AdSafetyConfig.placementDailyCapReached(placement)) {
      SafeLogger.d(_tag,
          '⏭️ showInterstitial skipped — placement daily cap reached ($placement)');
      _emitSkip(AdSlotType.interstitial, 'show', 'placement_cap',
          placement: placement);
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
        AdSafetyConfig.recordPlacementAdShown(placement); // T92
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
    // T64 — a slot can finish loading+caching while consent was still
    // granted, then have consent revoked before the actual show call. Cache
    // readiness must not outlive consent.
    if (!canRequestAds) return false;
    if (ad.interstitialSlot.isShowing) return false;
    if (AdLoadingDialog.isShowing) return false;
    // Peek, not canShowFullscreenAd() — this is a read-only "should I enable
    // my UI" query a host may poll repeatedly; the non-peek variant has a
    // CTR-anomaly side effect that would otherwise re-arm/escalate a
    // suspicious-pause window forever on every poll (2026-08-16 audit).
    final s = AdSafetyConfig.canShowFullscreenAdPeek();
    if (!s.canShow) return false;
    // m18 — `ready` alone is not showable: a cached AdMob ad expires after 1h
    // and showInterstitial() discards it instead of showing it. Reporting
    // `true` for one just makes a polling host enable a button that does
    // nothing. Same `is AdMobAdapter` shape as reviveNativeInstance above —
    // AppLovin has no documented cache expiry.
    if (ad is AdMobAdapter && !ad.isFullscreenSlotFresh(ad.interstitialSlot)) {
      return false;
    }
    return ad.interstitialSlot.isReady;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  REWARDED — load/show/canShow, plus the on-demand load path used when a
  //  VIP member watches an ad to extend their own VIP window
  //  (`bypassVipGuard`).
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadRewardedAd(
      {Duration watchdog = const Duration(seconds: 30)}) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — adapter null');
      _emitSkip(AdSlotType.rewarded, 'load', 'adapter_null');
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — VIP member');
      _emitSkip(AdSlotType.rewarded, 'load', 'vip');
      return;
    }
    if (AdSafetyConfig.dailyCapReached()) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — daily cap reached');
      _emitSkip(AdSlotType.rewarded, 'load', 'daily_cap');
      return;
    }
    if (!canRequestAds) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.rewarded, 'load', 'consent');
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — no network');
      _emitSkip(AdSlotType.rewarded, 'load', 'no_network');
      return;
    }
    await ad.loadRewarded();
    _armLoadWatchdog('rewarded', ad.rewardedSlot, watchdog);
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
      _emitSkip(AdSlotType.rewarded, 'show', 'adapter_null',
          placement: placement);
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
      _emitSkip(AdSlotType.rewarded, 'show', 'vip', placement: placement);
      onEarnedReward(vipAutoGrant);
      return;
    }
    // T03 — no impression without consent. (The vipAutoGrant-no-ad path above
    // already returned; this only gates paths that would actually show an ad.)
    if (!canRequestAds) {
      SafeLogger.d(_tag, '⏭️ showRewarded skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.rewarded, 'show', 'consent', placement: placement);
      onEarnedReward(false);
      return;
    }
    // Re-entrancy guard: a second call while the on-demand load OR the ad show
    // of a first call is still in flight would clobber state (two loaders, two
    // shows). Self-contained so the SDK is safe even without a caller-side lock.
    // C3 — `_rewardedInFlight` still covers re-entrancy of THIS call (an
    // on-demand load in flight is not yet "showing"); the shared mutex covers
    // every other fullscreen surface, which this path used to ignore.
    final busyR = _rewardedInFlight
        ? 'rewarded load/show in flight'
        : _fullscreenBusyReason;
    if (busyR != null) {
      SafeLogger.d(_tag, '⏭️ showRewarded skipped — $busyR');
      _emitSkip(AdSlotType.rewarded, 'show', 'busy', placement: placement);
      onEarnedReward(false);
      return;
    }
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) {
      SafeLogger.d(
          _tag, () => '⏭️ showRewarded blocked by safety: ${safety.reason}');
      _emitSkip(AdSlotType.rewarded, 'show', 'cooldown', placement: placement);
      onEarnedReward(false);
      return;
    }
    // T92 — additional per-placement daily cap, on top of (never instead
    // of) the global one just above.
    if (AdSafetyConfig.placementDailyCapReached(placement)) {
      SafeLogger.d(_tag,
          '⏭️ showRewarded skipped — placement daily cap reached ($placement)');
      _emitSkip(AdSlotType.rewarded, 'show', 'placement_cap',
          placement: placement);
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
      if (ctx == null) {
        // No live navigator context — can't show a blocking dialog, so the
        // on-demand wait below runs with no loading UI at all. Rare (splash
        // not yet attached, or the key was never wired) but silent otherwise,
        // so at least surface it for diagnostics.
        SafeLogger.w(_tag,
            '⚠️ showRewarded (bypass) — no navigator context, on-demand load will run without a loading dialog');
      }
      var shownOwnDialog = false;
      if (ctx != null) {
        // AdLoadingDialog.dismiss() wraps its Navigator pop in try/catch;
        // show()'s showDialog call had no equivalent protection — if it
        // throws (torn-down navigator, disposed context), _rewardedInFlight
        // would stay stuck true and block every showRewardedAd() call for
        // the rest of the session.
        try {
          AdLoadingDialog.show(ctx);
          // m4 — show() is a no-op when a dialog is already up, so assuming
          // ownership from "the call did not throw" would let us dismiss
          // someone else's dialog. Ask the class what actually happened.
          shownOwnDialog = AdLoadingDialog.isShowing;
        } catch (e) {
          // resetState() (not just clearing our own flag) — show() already
          // set AdLoadingDialog._isShowing = true before the throwing call,
          // and that flag feeds _fullscreenBusyReason, which gates EVERY
          // fullscreen ad surface (app open, interstitial, rewarded). Leaving
          // it stuck true would deadlock all of them, not just rewarded.
          AdLoadingDialog.resetState();
          _rewardedInFlight = false;
          SafeLogger.e(
              _tag, '⏭️ showRewarded (bypass) — loading dialog failed: $e');
          onEarnedReward(false);
          return;
        }
      }
      final loaded =
          await _loadRewardedOnDemand(ad, timeout: onDemandLoadTimeout);
      // MJ17 — only dismiss a dialog THIS call put up. It used to fire
      // unconditionally, including when `show()` was skipped for a null
      // context, so during the on-demand rewarded load (up to 15 s, and not
      // covered by `_fullscreenBusyReason`) it could tear down a buffer dialog
      // that a resume had opened for something else entirely.
      if (shownOwnDialog) AdLoadingDialog.dismiss();
      if (!loaded) {
        _rewardedInFlight = false;
        SafeLogger.d(_tag, '⏭️ showRewarded (bypass) — on-demand load failed');
        onEarnedReward(false);
        return;
      }
      // The on-demand load can take seconds, during which another fullscreen
      // surface that doesn't check `_rewardedInFlight` (app-open, interstitial)
      // may have started showing — re-check the shared mutex before actually
      // presenting, or this ad would stack on top of it.
      final busyAfterLoad = _fullscreenBusyReason;
      if (busyAfterLoad != null) {
        _rewardedInFlight = false;
        SafeLogger.d(_tag, '⏭️ showRewarded (bypass) skipped — $busyAfterLoad');
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
            AdSafetyConfig.recordPlacementAdShown(placement); // T92
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

  // ──────────────────────────────────────────────────────────────────────────
  //  REWARDED INTERSTITIAL (T89, AdMob only) — Google's format shown at a
  //  natural transition point, not behind an explicit "watch ad" tap. No
  //  VIP-bypass-to-extend-VIP flow and no SSV params here (unlike
  //  showRewardedAd) — see AdProviderAdapter.showRewardedInterstitial's doc
  //  comment for why. AppLovin MAX has no equivalent ad unit type;
  //  AppLovinAdapter's implementation is a documented no-op, so on that
  //  provider this slot never becomes ready and showRewardedInterstitialAd
  //  always reports `shown: false`.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadRewardedInterstitialAd(
      {Duration watchdog = const Duration(seconds: 30)}) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ loadRewardedInterstitial skipped — adapter null');
      _emitSkip(AdSlotType.rewardedInterstitial, 'load', 'adapter_null');
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ loadRewardedInterstitial skipped — VIP member');
      _emitSkip(AdSlotType.rewardedInterstitial, 'load', 'vip');
      return;
    }
    if (AdSafetyConfig.dailyCapReached()) {
      SafeLogger.d(
          _tag, '⏭️ loadRewardedInterstitial skipped — daily cap reached');
      _emitSkip(AdSlotType.rewardedInterstitial, 'load', 'daily_cap');
      return;
    }
    if (!canRequestAds) {
      SafeLogger.d(_tag,
          '⏭️ loadRewardedInterstitial skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.rewardedInterstitial, 'load', 'consent');
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, '⏭️ loadRewardedInterstitial skipped — no network');
      _emitSkip(AdSlotType.rewardedInterstitial, 'load', 'no_network');
      return;
    }
    await ad.loadRewardedInterstitial();
    _armLoadWatchdog(
        'rewardedInterstitial', ad.rewardedInterstitialSlot, watchdog);
  }

  Future<void> showRewardedInterstitialAd({
    required void Function(bool shown, bool earned) onDone,
    AdPlacement placement = AdPlacement.unspecified,
  }) async {
    final ad = _adapter;
    if (ad == null) {
      SafeLogger.d(_tag, '⏭️ showRewardedInterstitial skipped — adapter null');
      _emitSkip(AdSlotType.rewardedInterstitial, 'show', 'adapter_null',
          placement: placement);
      onDone(false, false);
      return;
    }
    if (_isVipMember) {
      SafeLogger.d(_tag, '⏭️ showRewardedInterstitial skipped — VIP member');
      _emitSkip(AdSlotType.rewardedInterstitial, 'show', 'vip',
          placement: placement);
      onDone(false, false);
      return;
    }
    if (!canRequestAds) {
      SafeLogger.d(_tag,
          '⏭️ showRewardedInterstitial skipped — consent not granted (UMP)');
      _emitSkip(AdSlotType.rewardedInterstitial, 'show', 'consent',
          placement: placement);
      onDone(false, false);
      return;
    }
    final busyRI = _fullscreenBusyReason;
    if (busyRI != null) {
      SafeLogger.d(_tag, '⏭️ showRewardedInterstitial skipped — $busyRI');
      _emitSkip(AdSlotType.rewardedInterstitial, 'show', 'busy',
          placement: placement);
      onDone(false, false);
      return;
    }
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) {
      SafeLogger.d(
          _tag,
          () =>
              '⏭️ showRewardedInterstitial blocked by safety: ${safety.reason}');
      _emitSkip(AdSlotType.rewardedInterstitial, 'show', 'cooldown',
          placement: placement);
      onDone(false, false);
      return;
    }
    // T92 — additional per-placement daily cap, on top of (never instead
    // of) the global one just above.
    if (AdSafetyConfig.placementDailyCapReached(placement)) {
      SafeLogger.d(_tag,
          '⏭️ showRewardedInterstitial skipped — placement daily cap reached ($placement)');
      _emitSkip(AdSlotType.rewardedInterstitial, 'show', 'placement_cap',
          placement: placement);
      onDone(false, false);
      return;
    }
    final arbitrator = _arbitrator;
    if (arbitrator != null &&
        arbitrator.decide(AdSlotType.rewardedInterstitial) ==
            ArbitratorDecision.nudgeVip) {
      SafeLogger.d(
          _tag, '⏭️ showRewardedInterstitial vetoed — arbitrator nudgeVip');
      _emit(ArbitratorNudgeEvent(
        type: AdSlotType.rewardedInterstitial,
        placement: placement,
        estimatedEcpmMicros: arbitrator.estimatedEcpmMicros,
      ));
      onDone(false, false);
      return;
    }
    await ad.showRewardedInterstitial(onDone: (result) {
      if (result.earned) {
        AdSafetyConfig.recordFullscreenAdShown();
        AdSafetyConfig.recordPlacementAdShown(placement); // T92
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
        type: AdSlotType.rewardedInterstitial,
        placement: placement,
        success: result.earned,
      ));
      onDone(result.shown, result.earned);
      unawaited(loadRewardedInterstitialAd());
    });
  }

  bool canShowRewardedInterstitialAd() {
    final ad = _adapter;
    if (ad == null) return false;
    if (_isVipMember) return false;
    if (!canRequestAds) return false;
    if (ad.rewardedInterstitialSlot.isShowing) return false;
    // Peek, not canShowFullscreenAd() — see canShowInterstitial's comment.
    final s = AdSafetyConfig.canShowFullscreenAdPeek();
    if (!s.canShow) return false;
    // m18 — see canShowInterstitial. This peek was missed when m18 wired the
    // other two (round-3 QC finding): without it a host polling this method
    // gets `true` for an ad the show path would discard as stale.
    if (ad is AdMobAdapter &&
        !ad.isFullscreenSlotFresh(ad.rewardedInterstitialSlot)) {
      return false;
    }
    return ad.rewardedInterstitialSlot.isReady;
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
    // Deliberately BEFORE the consent check: this is a UI-gating quirk (the
    // VIP watch-to-extend button), not a real ad path — see showRewardedAd's
    // vipAutoGrant handling. Untouched by T64.
    if (_isVipMember) return true;
    // T64 — a slot can finish loading+caching while consent was still
    // granted, then have consent revoked before the actual show call. Cache
    // readiness must not outlive consent.
    if (!canRequestAds) return false;
    if (ad.rewardedSlot.isShowing) return false;
    if (AdLoadingDialog.isShowing) return false;
    // Peek, not canShowFullscreenAd() — see canShowInterstitial's comment.
    final s = AdSafetyConfig.canShowFullscreenAdPeek();
    if (!s.canShow) return false;
    // m18 — see canShowInterstitial.
    if (ad is AdMobAdapter && !ad.isFullscreenSlotFresh(ad.rewardedSlot)) {
      return false;
    }
    return ad.rewardedSlot.isReady;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  BANNER — single load-if-needed entry point; state/cooldown/accessors
  //  live in the "Banner accessors" section near the top of the class.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadAdmobBannerIfNeeded(Object key, double widthPx) async {
    final ad = _adapter;
    if (ad == null) return;
    if (_isVipMember || !isConnected) return;
    await ad.loadBannerIfNeeded(key, widthPx);
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  MREC — load-if-needed for MREC + native; state/accessors live in the
  //  "MREC/Native accessors" sections near the top of the class.
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> loadAdmobMrecIfNeeded(Object key, double widthPx) async {
    final ad = _adapter;
    if (ad == null) return;
    if (_isVipMember || !isConnected) return;
    await ad.loadMrecIfNeeded(key, widthPx);
  }

  Future<void> loadAdmobNativeIfNeeded(Object key,
      {TemplateType templateType = TemplateType.medium}) async {
    final ad = _adapter;
    if (ad == null) return;
    if (_isVipMember || !isConnected) return;
    await ad.preloadNative(key, templateType: templateType);
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
    if (state == AppLifecycleState.resumed) {
      // B3 follow-up (audit_claude.md, 2026-08-20) — Stopwatch-based drift
      // detection in VipManager._effectiveNow misreads a normal sleep/
      // background gap as clock tamper (monotonic uptime clock pauses
      // during suspend; wall clock doesn't). Re-anchor on every resume so
      // drift detection only covers time spent actively foregrounded.
      _vipManager?.resyncSessionClock();
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
          '| appOpen=${ad?.appOpenSlot.value.name ?? "?"}'
          // T65 (phase 2): banner is now keyed per BannerAdWidget instance —
          // no single slot to summarize here anymore.
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
      // T70 — flush any debounced compliance-log write now, before the
      // process could be killed while backgrounded.
      unawaited(_eventLog?.flush() ?? Future<void>.value());
      AdSafetyConfig.recordAppWentBackground();
      try {
        ad.onAppPaused();
      } catch (e, st) {
        SafeLogger.e(_tag, 'onAppPaused threw: $e\n$st');
      }
    } else if (state == AppLifecycleState.resumed) {
      // Round-13 QC (round 2), BLOCKER ×2 — NOTHING that can request or show
      // an ad may run before the resume consent re-check has settled. See
      // [_resumeAdWorkAfterConsent]: `onAppResumed()` is not a passive
      // notification, it recreates failed banners/MRECs and re-enables
      // auto-refresh, i.e. it requests ads — with whatever consent is applied
      // at that moment. A withdrawal the user made while the app was
      // backgrounded is applied first now, or no ad work happens at all.
      unawaited(_resumeAdWorkAfterConsent(ad));
    }
  }

  /// How long a resume waits for the consent re-check before giving up on ad
  /// work for that resume. Overridable in tests only.
  static const Duration _resumeConsentRecheckTimeout = Duration(seconds: 5);

  @visibleForTesting
  static Duration? debugResumeConsentRecheckTimeout;

  /// Round-13 QC (round 2), BLOCKER — the resume ad work, gated on consent.
  ///
  /// Fail-closed on purpose: if the re-check cannot settle (a wedged platform
  /// channel, storage that throws) this resume does no ad work at all. The two
  /// outcomes are not symmetrical — a fill served under a consent the user has
  /// withdrawn is a compliance violation, while a skipped banner refresh and
  /// App Open costs one resume and is retried on the next one.
  Future<void> _resumeAdWorkAfterConsent(AdProviderAdapter ad) async {
    final timeout =
        debugResumeConsentRecheckTimeout ?? _resumeConsentRecheckTimeout;
    try {
      await _recheckConsentOnResume().timeout(timeout);
    } on TimeoutException {
      SafeLogger.w(
          _tag,
          'resume consent re-check did not settle in ${timeout.inSeconds}s — '
          'skipping ad work for this resume rather than risking a fill under '
          'stale consent');
      return;
    } catch (e, st) {
      SafeLogger.e(
          _tag,
          '_recheckConsentOnResume threw: $e\n$st — skipping ad work for this '
          'resume, the consent state could not be confirmed');
      return;
    }
    // A late-dismiss apply may still be mid-write (see
    // [_applyPrivacyOptionsResult]); its answer is newer than anything we
    // could show, so let it land and pick the ads up on the next resume.
    if (_consentApplyRunning) {
      SafeLogger.w(
          _tag,
          'a consent apply is still in flight on resume — skipping ad work '
          'until it has landed');
      return;
    }
    // Round-13 QC (round 4), MAJOR — `destroy()` + re-initialise can swap the
    // adapter out while the re-check is in flight. Calling into the old one
    // would drive a disposed native channel (and could recreate ads on it), so
    // this resume is simply dropped: the new adapter gets its own resume.
    if (!identical(_adapter, ad)) {
      SafeLogger.w(
          _tag,
          'the adapter was replaced while the resume consent re-check was in '
          'flight — dropping the ad work for this resume');
      return;
    }
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
      // C2 backstop — _onConnectivityChanged only retries a failed UMP
      // attempt on an observed offline→online transition. A platform/test
      // where the connectivity plugin never fires that transition (see
      // _startConnectivityWatch's best-effort skip) would otherwise never
      // retry UMP at all. Same guards _retryRefillAds uses below.
      // m11 — bounded, and never for a user who already answered. See
      // [_umpAnswered] and [_maxUmpBackstopRetries].
      if (_umpAttemptFailed &&
          isConnected &&
          !_isVipMember &&
          !_umpAnswered &&
          _umpBackstopRetryCount < _maxUmpBackstopRetries) {
        if (_umpFormAbandoned) {
          // M-3 — a form may still be on screen; recheck status instead of
          // risking a second one. Not counted against the retry budget: it
          // never touches the network or the native form.
          unawaited(_recheckAbandonedUmpForm());
        } else {
          SafeLogger.d(_tag, '🔐 retrying UMP consent on periodic backstop');
          _umpBackstopRetryCount++;
          unawaited(_retryUmpConsent());
        }
      }
      _retryRefillAds();
      _scheduleNextRetry(gen);
      // m12 — _startConnectivityWatch() is called exactly once, from
      // initialize(), and is best-effort: a plugin init that throws or times
      // out leaves _connectivityReady false forever. isConnected then falls
      // back to its optimistic `true` seed, so the SDK believes it is always
      // online — every offline load just fails into backoff — and the
      // refill-on-reconnect fast path is gone for the whole session. One
      // re-attempt per poll tick costs nothing when it is already up, and is
      // idempotent (the generation token inside handles overlap).
      //
      // Deliberately LAST, and with its own error sink: this is opportunistic
      // repair, so it must never be able to skip the refill scan or the
      // reschedule above — doing it first stopped the timer dead on any
      // platform where the connectivity plugin is absent.
      // m10 (independent review) — the reviewer asked for `_connectivityReady`
      // to be reset in `_resetGuardState()`. Rejected after reading
      // connectivity_refill_test.dart, which documents it as process/plugin
      // level state (ConnectionNotifierTools initialises once per process) and
      // asserts destroy() must NOT reset it, or every re-init re-opens the
      // silent pre-ready read window.
      //
      // The residual gap is real but narrower and deliberately left: a
      // teardown cancels `_connectivitySub`, so after a re-init whose watch
      // failed we can be "ready" with no live subscription and therefore no
      // refill-on-reconnect. Gating this re-attempt on the subscription
      // instead would fix it, but under `flutter test` the connectivity
      // checker then runs for real, every HTTP probe returns 400, it concludes
      // offline, and `canReload()` starves every later refill — so it would
      // cost test-only seams to buy back a path the 5-minute poll already
      // covers, just less promptly.
      if (!_connectivityReady) {
        SafeLogger.d(_tag, '📶 connectivity watch not ready — re-attempting');
        unawaited(_startConnectivityWatch().catchError((Object e) {
          SafeLogger.d(_tag, () => 'connectivity re-attempt failed: $e');
        }));
      }
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
    //
    // This is called `unawaited` from `initialize()`, which can itself
    // finish (and reset `_isInitializing`) well before this up-to-20s await
    // resolves — so a SECOND `initialize()` call can start a second overlapping
    // invocation of this method before the first one's `await` below returns
    // (2026-08-16 audit). Whichever resolved LAST would otherwise silently
    // overwrite `_connectivitySub` with its own, leaking the other's
    // subscription forever. The generation token below makes a call that
    // loses the race bail out before ever subscribing, instead of clobbering
    // (or being clobbered by) a newer one.
    final myGen = ++_connectivityWatchGen;
    try {
      // R10-D — bound the native call the same way adapter.initialize() is
      // bounded above: an unresponsive plugin must not hang the SDK forever.
      await _connectivityInit().timeout(const Duration(seconds: 20));
      if (myGen != _connectivityWatchGen) {
        SafeLogger.d(_tag,
            'connectivity watch: a newer call already won, discarding this one');
        return;
      }
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
    _connectivityWatchGen++;
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
      // C2 — a UMP attempt that failed offline was never retried, so an EEA
      // user whose first launch had no network never saw a consent form for
      // the rest of the process: ads were refilled but the gate stayed at
      // whatever UMP had cached. Retry only when the previous attempt actually
      // failed, so a user who already answered is not shown the form again.
      if (_umpAttemptFailed && !_umpAnswered) {
        if (_umpFormAbandoned) {
          // M-3 — same reasoning as the periodic backstop: a form may still
          // be on screen, so recheck instead of risking a second one.
          unawaited(_recheckAbandonedUmpForm());
        } else {
          SafeLogger.d(_tag, '🔐 retrying UMP consent after reconnect');
          unawaited(_retryUmpConsent());
        }
      }
      _retryRefillAds();
      // Banners re-run their init on an initRevision bump (the widget checks
      // isConnected in _initBanner); also nudge the adapter's banner preload
      // for the case where no widget is mounted yet — T65 (phase 2): shares
      // the sentinel key (see its doc comment), same trade-off as the other
      // two keyless call sites.
      unawaited(_adapter?.preloadBanner(_globalBannerWarmupKey) ??
          Future<void>.value());
      // T67 — reconnect nudged the banner's AppLovin bridge-level preload
      // cache above but never MREC's, so its cache stayed empty until the
      // next SDK init / VIP-expiry preload. Native has no equivalent: both
      // providers' preloadNative() are intentional no-ops (native loads on
      // widget mount only), so there's nothing to refill there.
      unawaited(
          _adapter?.preloadMrec(_globalMrecWarmupKey) ?? Future<void>.value());
      initRevision.value = initRevision.value + 1;
    });
  }

  void _retryRefillAds() {
    // R10-C — don't even attempt a refill scan while offline; every load*()
    // call below would just fail immediately and log noise.
    if (!isConnected) return;
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
    // 2026-08-16 audit: rewardedInterstitial (T89, AdMob-only) was missing
    // from this backstop entirely — if its first load ever failed (no
    // network, no-fill) and it was never shown, nothing else refills it.
    // On AppLovin this slot never leaves idle by design (see
    // AppLovinAdapter's documented no-op), so this is a harmless extra
    // no-op call there, same as every other load*() call in this scan
    // already tolerates per-provider no-ops.
    if (ad.rewardedInterstitialSlot.isIdle ||
        ad.rewardedInterstitialSlot.isCooldown) {
      unawaited(loadRewardedInterstitialAd());
    }
    // MJ20 note: this scan still covers only the four fullscreen slots.
    // Nudging stalled banner/mrec/native slots from here as well was tried and
    // dropped — the watchdog added in AdMobAdapter is the root-cause fix (the
    // slot now lands in `cooldown`, which a widget remount retries, instead of
    // being stuck `loading` and refusing every later beginLoad forever), and
    // reaching those slot collections from here forces the new getter onto
    // ~15 test fakes for a second, redundant recovery path. Revisit only if a
    // real stall survives a remount.
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
