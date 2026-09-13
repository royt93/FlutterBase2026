import 'dart:async';
import 'dart:convert' show JsonEncoder;
import 'dart:io' show Platform;
import 'dart:math' as math;

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
import '../compliance/bypass_audit_trail.dart';
import '../compliance/compliance_signing.dart';
import '../compliance/incident_recorder.dart';
import '../config/ad_config.dart';
import '../config/feature_flags.dart';
import '../monetization/revenue_anomaly_detector.dart';
import '../consent/consent_fallback.dart';
import '../config/remote_ad_safety_provider.dart';
import '../consent/consent_manager.dart';
import '../consent/consent_settings.dart';
import '../monetization/ad_diagnostics.dart';
import '../monetization/fill_rate_baseline_monitor.dart';
import '../monetization/fill_rate_monitor.dart';
import '../monetization/journey_prefetcher.dart';
import '../monetization/digital_twin.dart';
import '../monetization/self_healing_observer.dart';
import '../monetization/waterfall_tuner.dart';
import '../monetization/monetization_arbitrator.dart';
import '../monetization/provider_failover_advisor.dart';
import '../monetization/revenue_integrity_ledger.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_sdk_state_snapshot.dart';
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

/// T144 — the 3 signed exports [AdManager] already had, bundled into one
/// artifact via [AdManager.exportDisputeKit]. Each field verifies
/// independently with its own existing verifier
/// ([verifySignedComplianceReportJson] / [verifySignedJsonPayload]) — this
/// class is pure aggregation, it introduces no new signing/redaction logic.
class DisputeKit {
  const DisputeKit({
    required this.compliance,
    required this.bypassAuditTrail,
    required this.incidentBundle,
  });

  final SignedComplianceReport compliance;
  final SignedPayload bypassAuditTrail;
  final SignedPayload incidentBundle;

  Map<String, dynamic> toJson() => {
        'compliance': compliance.toJson(),
        'bypassAuditTrail': bypassAuditTrail.toJson(),
        'incidentBundle': incidentBundle.toJson(),
      };

  String toJsonString({bool pretty = false}) {
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(toJson());
  }
}

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
    // T168 — same reasoning: lives for the whole process.
    customOverlayOnScreen.addListener(_recomputeFullscreenBusy);
    // codex review (T168, round 1) — a host can call
    // markCustomOverlayOnScreen(true) before ever touching AdManager (it is
    // a plain top-level function), so by the time this constructor runs the
    // flag can already be true. The listeners above only react to a FUTURE
    // change; without this, `fullscreenBusy` would stay stuck at its false
    // default — wrong, though harmless to actual gating, since every real
    // show path reads _fullscreenBusyReason directly rather than this
    // mirror — until some other busy input flips. Seed it once, now.
    _recomputeFullscreenBusy();
    // T109 — same reasoning: these three also live for the whole process.
    _offlineNotifier.addListener(_scheduleStateSnapshotRecompute);
    _canRequestAdsNotifier.addListener(_scheduleStateSnapshotRecompute);
    initRevision.addListener(_scheduleStateSnapshotRecompute);
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

  /// T140 — resolves this session's [AdConfig.placements] registry (if
  /// any) for [placement], returning its [PlacementSpec.frequencyCapOverride]
  /// to feed into [AdSafetyConfig.placementDailyCapReached]'s
  /// `capOverride` at every fullscreen show call site. `null` whenever
  /// `placements` isn't configured, or has no entry for this exact
  /// placement — every existing caller (no registry ever set up) sees
  /// unchanged behavior.
  ///
  /// Round-2 independent review (IMPORTANT) — [actualFormat] is REQUIRED
  /// and checked against [PlacementSpec.format]: a mismatch returns `null`
  /// (no override applied) instead of silently applying a cap meant for a
  /// DIFFERENT format. Without this, a host that happens to reuse the same
  /// [AdPlacement.id] across two different ad formats (nothing stops
  /// that — `AdPlacement` doesn't carry a format itself) would have a
  /// spec registered for e.g. `interstitial` silently also gate
  /// `showRewardedAd`/`showAppOpenAd`/`showRewardedInterstitialAd` calls
  /// that happen to reuse that same id — the exact opposite of what a
  /// required `format` field on the spec is supposed to prevent.
  int? _placementCapOverride(AdPlacement placement, AdSlotType actualFormat) {
    final spec = _config?.placements?[placement.id];
    if (spec == null || spec.format != actualFormat) return null;
    return spec.frequencyCapOverride;
  }

  /// T181 — same resolution/format-match rules as [_placementCapOverride],
  /// feeding [AdSafetyConfig.canShowFullscreenAd]'s `minIntervalOverrideMs`
  /// instead of `placementDailyCapReached`'s `capOverride`.
  int? _placementMinIntervalOverride(
      AdPlacement placement, AdSlotType actualFormat) {
    final spec = _config?.placements?[placement.id];
    if (spec == null || spec.format != actualFormat) return null;
    return spec.minIntervalOverrideMs;
  }

  /// T111 — kept from the last [initialize] call so [refreshRemoteSafetyParams]
  /// can re-fetch without a full destroy()+initialize() cycle. Cleared by
  /// [destroy] alongside [_config].
  RemoteAdSafetyProvider? _remoteSafetyProvider;

  /// T137 — periodic auto-refresh, opt-in via `initialize`'s
  /// `remoteSafetyAutoRefreshInterval`. `null` unless that param was set.
  /// Cancelled by [_resetGuardState] alongside every other Timer field.
  Timer? _remoteSafetyRefreshTimer;

  /// T137 — see [_applyRemoteOverridesWithRevisionGuard]'s doc comment for
  /// why this is a plain in-memory field, not just read from [AdPreferences]
  /// each time.
  int? _lastAppliedRemoteSafetyRevision;

  @visibleForTesting
  set debugRemoteSafetyProvider(RemoteAdSafetyProvider? p) =>
      _remoteSafetyProvider = p;

  /// T137 — test-only reset for [_lastAppliedRemoteSafetyRevision]. A test
  /// file whose `tearDown` clears the other `debugRemoteSafetyProvider`-
  /// adjacent state via debug setters (rather than a real `destroy()`,
  /// which reaches [_resetGuardState] on its own) needs this one too, or
  /// a revision one test applies leaks into the next test's guard check.
  @visibleForTesting
  set debugLastAppliedRemoteSafetyRevision(int? v) =>
      _lastAppliedRemoteSafetyRevision = v;

  @visibleForTesting
  bool get debugRemoteSafetyRefreshTimerActive =>
      _remoteSafetyRefreshTimer?.isActive ?? false;

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

  /// Round-25 QC round 13 (`codex`, MAJOR) — this returns `null` while a
  /// teardown is in flight. `AdProviderAdapter` is exported and its
  /// `showAppOpen`/`showInterstitial`/`showRewarded`/`showRewardedInterstitial`
  /// are public, so a host that fetched the adapter through here could show a
  /// fullscreen ad straight past every guard in this class while `destroy()`
  /// was dismantling the very session behind it. Handing back `null` closes
  /// that door without touching the exported abstract interface (adding a
  /// member there would be a breaking change for anyone implementing it).
  /// Internal callers use `_adapter` and are unaffected; the banner/MREC/native
  /// widgets do come through here, and stopping them from building against an
  /// adapter about to be disposed is the point, not a side effect.
  AdProviderAdapter? get adapter => _destroyInFlight != null ? null : _adapter;

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

  /// Round-31 audit fix (MAJOR) — [consentFootgunWarning] above only
  /// catches "no consent flow ran at all". A host that declares
  /// `isAgeRestrictedUser: true` (COPPA/child-directed) but leaves
  /// [AdConfig.umpTagForUnderAgeOfConsent] at its `false` default while a
  /// UMP flow DOES run has no warning today: Google's standard consent
  /// form (206-partner personalized-ads disclosure) shows to a
  /// self-declared child-directed audience with no signal telling UMP to
  /// treat this as an under-13 session. Pure + static so it is
  /// unit-testable without running the full native init, same contract as
  /// [consentFootgunWarning].
  @visibleForTesting
  static String? coppaUmpMismatchWarning(AdConfig config,
      {required bool isAgeRestrictedUser, required bool umpWillRun}) {
    if (!isAgeRestrictedUser ||
        !umpWillRun ||
        config.umpTagForUnderAgeOfConsent) {
      return null;
    }
    return '🚨 isAgeRestrictedUser is true (COPPA/child-directed) but '
        "AdConfig.umpTagForUnderAgeOfConsent is false while a UMP consent "
        'flow will run — Google\'s standard consent form may show to a '
        'self-declared under-13 audience with no under-age signal set. Set '
        'AdConfig(umpTagForUnderAgeOfConsent: true, ...) for a '
        'child-directed app.';
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
    if (gaid.isNotEmpty && gaid.toLowerCase() != _zeroGaid) {
      return experiment.experimentBucket(gaid, key, buckets: buckets);
    }
    final prefs = AdPreferences.instanceOrNull;
    final installId =
        prefs?.getOrCreateExperimentInstallId() ?? _preInitExperimentId();
    return experiment.experimentBucket(installId, key, buckets: buckets);
  }

  /// Round-27 backlog B1 (P0) — [experimentBucket] used to fall back to the
  /// empty string whenever [AdPreferences] hadn't bootstrapped yet, which is
  /// ALWAYS true the moment this method's own docstring says to call it:
  /// before [initialize]. Every device hashed `''`, collapsing 100% of
  /// installs into the same bucket — [pickProviderCohort]'s A/B split was a
  /// no-op for anyone following the documented call order. Mints a random id
  /// once per process (stable for this run, so a session's bucket never
  /// flips mid-session) and hands it to [AdPreferences] to persist as soon
  /// as it bootstraps, so the SAME id — not a second random one — wins and
  /// becomes stable across future launches too.
  String? _cachedPreInitExperimentId;

  /// Test seam — clears the process-lifetime cache so a test can simulate a
  /// fresh, never-bootstrapped install instead of inheriting whatever a
  /// prior test in the same run already minted.
  @visibleForTesting
  void debugResetPreInitExperimentId() => _cachedPreInitExperimentId = null;

  String _preInitExperimentId() {
    final cached = _cachedPreInitExperimentId;
    if (cached != null) return cached;
    final id = AdPreferences.generateRandomId();
    _cachedPreInitExperimentId = id;
    unawaited(AdPreferences.getInstance()
        .then((p) => p.seedExperimentInstallIdIfAbsent(id)));
    return id;
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

  /// T136 — session-alternate exploration for [WaterfallTuner]/
  /// [SelfHealingObserver]: with probability [explorationRate] (default 0,
  /// i.e. off), returns the OTHER provider instead of
  /// [installCohortProvider] for THIS session only — [pickProviderCohort]'s
  /// own per-install assignment is unaffected, this only changes what a
  /// single app launch requests ads from. Call this the same way as
  /// [pickProviderCohort] — BEFORE building [AdConfig] — passing whatever
  /// [pickProviderCohort] (or your own stable per-install assignment)
  /// already returned:
  ///
  /// ```dart
  /// final installProvider = AdManager().pickProviderCohort();
  /// final sessionProvider = await AdManager().pickSessionProvider(
  ///   installCohortProvider: installProvider,
  ///   explorationRate: 0.05, // 5% of eligible sessions explore
  /// );
  /// await AdManager().initialize(
  ///   config: AdConfig(provider: sessionProvider, admob: ..., appLovin: ...),
  ///   onComplete: (success, gaid) { /* ... */ },
  /// );
  /// ```
  ///
  /// This is a REAL session on the alternate provider — real ad requests,
  /// real fills, real revenue — not a shadow request; see [WaterfallTuner]'s
  /// doc comment for why a shadow request was rejected instead. The
  /// tradeoff is real too: an explored session may perform worse than the
  /// install's normal provider for that session's users — that is the
  /// actual cost of an on-device A/B comparison, not a bug. Keep
  /// [explorationRate] low (the default 0 means "never"; anything above 0
  /// is an explicit choice).
  ///
  /// [minIntervalBetweenExplorations] rate-limits how often ANY session
  /// explores (persisted, survives app restarts) — the default of 1 day
  /// means at most one explored session per day regardless of how many
  /// times the app launches. This is `async` — round 2 of independent
  /// review (BLOCKER) caught that a synchronous version reading only
  /// [AdPreferences.instanceOrNull] saw `null` on a cold app launch (the
  /// singleton has no reason to already be populated that early), silently
  /// defeating the persisted rate limit on exactly the call pattern this
  /// method's own doc recommends (call it before the FIRST [initialize]).
  /// Awaiting [AdPreferences.getInstance] here loads it for real.
  ///
  /// VIP sessions are handled specially: VIP suppresses every ad surface,
  /// so an explored VIP session would waste a rare exploration slot on a
  /// session that could never produce [WaterfallTuner] data anyway — but
  /// VIP status is not known until AFTER every VIP-affecting phase of
  /// [initialize] has run (same constraint [pickProviderCohort] has), so
  /// this method cannot check it up front. Instead, the decision to
  /// actually COUNT this call against [minIntervalBetweenExplorations] is
  /// deferred until VIP status is truly final — see
  /// [_reconcileProviderExplorationSlot], invoked internally once
  /// `VipManager.load()`, the configured VIP GAID whitelist import, AND
  /// first-install VIP grace have ALL been applied (round 2 review,
  /// BLOCKER — reconciling right after `VipManager.load()` alone persisted
  /// the exploration before first-install grace could flip this session to
  /// VIP, wrongly counting it). A VIP session's provider choice for that
  /// session is still committed (there is no way to un-choose it after the
  /// fact), only the "did this count as today's explore" bookkeeping is
  /// skipped.
  Future<AdProvider> pickSessionProvider({
    required AdProvider installCohortProvider,
    double explorationRate = 0,
    Duration minIntervalBetweenExplorations = const Duration(days: 1),
    @visibleForTesting math.Random? debugRandom,
  }) async {
    // Clamp rather than assert — a misconfigured release build (a host
    // computing this rate dynamically, say) must fail safe toward "explore
    // never/always as documented", not silently accept e.g. 1.5 as "150%"
    // or a negative interval as "no rate limit at all".
    final rate = explorationRate.clamp(0.0, 1.0);
    final interval = minIntervalBetweenExplorations.isNegative
        ? Duration.zero
        : minIntervalBetweenExplorations;
    if (rate <= 0) return installCohortProvider;
    final prefs = await AdPreferences.getInstance();
    final lastMs = prefs.getLastProviderExplorationAtMs();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (lastMs != null && nowMs - lastMs < interval.inMilliseconds) {
      return installCohortProvider;
    }
    if ((debugRandom ?? math.Random()).nextDouble() >= rate) {
      return installCohortProvider;
    }
    // Committing the persisted timestamp is deferred to
    // _reconcileProviderExplorationSlot — see this method's doc comment
    // for why (VIP status not yet final at this point).
    _pendingExplorationCommitAtMs = nowMs;
    return installCohortProvider == AdProvider.admob
        ? AdProvider.appLovin
        : AdProvider.admob;
  }

  /// T136 — set by [pickSessionProvider] when it decides to explore this
  /// session. Captured into a local by [initialize] as the very first
  /// synchronous step (before any `await`) and cleared here immediately —
  /// see the capture site's comment for why this must not be read back
  /// from this field again after that point.
  int? _pendingExplorationCommitAtMs;

  /// T136 — call once per session, once VIP status is TRULY final (after
  /// `VipManager.load()`, the VIP GAID whitelist import, AND first-install
  /// VIP grace have all been applied inside [initialize] — see that call
  /// site). [pendingExplorationAtMs] is the value [initialize] captured
  /// from [_pendingExplorationCommitAtMs] at its own start, not read from
  /// the field again (a later, unrelated session may have already set a
  /// new one by the time this runs). If it is non-null, this is where that
  /// decision actually gets persisted against
  /// [AdPreferences.setLastProviderExplorationAtMs] — but only when
  /// [vipActive] is false. A VIP session's exploration attempt is
  /// discarded here (not persisted, not counted against the rate limit) —
  /// see [pickSessionProvider]'s doc comment for the full reasoning.
  ///
  /// `async` and meant to be `await`-ed by the caller (round 2 review,
  /// MAJOR) — a fire-and-forget write here could lose the daily-cap
  /// timestamp to a process kill right after [initialize] returns,
  /// silently permitting another explore sooner than intended.
  Future<void> _reconcileProviderExplorationSlot({
    required int? pendingExplorationAtMs,
    required bool vipActive,
  }) async {
    if (pendingExplorationAtMs == null || vipActive) return;
    final prefs = await AdPreferences.getInstance();
    await prefs.setLastProviderExplorationAtMs(pendingExplorationAtMs);
  }

  /// Test seam — exercises [_reconcileProviderExplorationSlot] directly,
  /// without needing a real [initialize] call to reach the point where VIP
  /// status becomes final.
  @visibleForTesting
  Future<void> debugReconcileProviderExplorationSlot({
    required bool vipActive,
  }) {
    final pendingMs = _pendingExplorationCommitAtMs;
    _pendingExplorationCommitAtMs = null;
    return _reconcileProviderExplorationSlot(
        pendingExplorationAtMs: pendingMs, vipActive: vipActive);
  }

  /// Test seam — exposes whether [pickSessionProvider] currently has an
  /// uncommitted exploration pending reconciliation.
  @visibleForTesting
  bool get debugHasPendingExplorationCommit =>
      _pendingExplorationCommitAtMs != null;

  /// Disposes [current] (if non-null) via [dispose] and returns [next] —
  /// the shared "swap out an opt-in feature" pattern behind every
  /// enable*/disable* pair below (arbitrator, fillRateMonitor,
  /// waterfallTuner, providerFailoverAdvisor, selfHealingObserver,
  /// journeyPrefetcher).
  ///
  /// Audit fix (post-T180) — these were six ~15-line copy-pasted
  /// "dispose old, assign new" bodies with no behavior difference between
  /// them (confirmed: every current call site disposes with default args,
  /// fire-and-forget, whether the underlying `dispose()` is sync `void` or
  /// async `Future<void>` — [dispose] just needs to be callable as a
  /// statement either way, which `void Function(T)` already permits). Kept
  /// generic rather than a shared interface: these six classes are
  /// otherwise unrelated and don't need one just for this.
  T? _swapDisposable<T>(T? current, T? next, void Function(T) dispose) {
    if (current != null) dispose(current);
    return next;
  }

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
    _arbitrator = _swapDisposable(_arbitrator, arbitrator, (a) => a.dispose());
  }

  /// Test/host seam: clear a previously-registered arbitrator.
  @visibleForTesting
  void disableArbitrator() {
    _arbitrator = _swapDisposable<MonetizationArbitrator>(
        _arbitrator, null, (a) => a.dispose());
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
    _fillRateMonitor =
        _swapDisposable(_fillRateMonitor, monitor, (m) => m.dispose());
  }

  /// Test/host seam: clear a previously-registered fill-rate monitor.
  @visibleForTesting
  void disableFillRateMonitor() {
    _fillRateMonitor = _swapDisposable<FillRateMonitor>(
        _fillRateMonitor, null, (m) => m.dispose());
  }

  /// T187 — opt-in revenue integrity ledger (default OFF) — `null` unless
  /// the host app calls [enableRevenueIntegrityLedger]. Purely
  /// observational, same shape as [enableFillRateMonitor]: it never
  /// affects show/load gating, it only watches [events] and flags a
  /// possible revenue-integrity gap via [incidentRecorder]. Read
  /// [RevenueIntegrityLedger]'s own doc comment for what "flagged" means
  /// (a heuristic signal, not a fraud verdict).
  RevenueIntegrityLedger? _revenueIntegrityLedger;

  /// `null` by default — see [enableRevenueIntegrityLedger].
  RevenueIntegrityLedger? get revenueIntegrityLedger => _revenueIntegrityLedger;

  /// Opt in to the revenue integrity ledger: starts watching [events] for
  /// successful shows without a timely matching revenue event.
  void enableRevenueIntegrityLedger(RevenueIntegrityLedger ledger) {
    _revenueIntegrityLedger = _swapDisposable(
        _revenueIntegrityLedger, ledger, (l) => l.dispose());
  }

  /// Test/host seam: clear a previously-registered revenue integrity ledger.
  @visibleForTesting
  void disableRevenueIntegrityLedger() {
    _revenueIntegrityLedger = _swapDisposable<RevenueIntegrityLedger>(
        _revenueIntegrityLedger, null, (l) => l.dispose());
  }

  /// T122 — opt-in on-device waterfall tuner (default OFF) — `null` unless
  /// the host app calls [enableWaterfallTuner]. Purely observational, same
  /// shape as [enableFillRateMonitor]: it never affects show/load gating or
  /// which provider a live session uses, it only watches [events] and
  /// exposes a per-(provider, format, placement) [WaterfallTuner.recommendation]
  /// a host can read and act on for its *next* `initialize()` call.
  WaterfallTuner? _waterfallTuner;

  /// `null` by default — see [enableWaterfallTuner].
  WaterfallTuner? get waterfallTuner => _waterfallTuner;

  /// Opt in to the waterfall tuner: starts tracking trailing fill rate and
  /// eCPM per (provider, format, placement) from [events].
  ///
  /// Read [WaterfallTuner]'s own doc comment before relying on
  /// [WaterfallTuner.recommendation] within a session — a single install
  /// runs exactly one provider for its whole lifetime, so that method
  /// cannot compare against real data for the other provider and will
  /// never return non-null on a real device.
  void enableWaterfallTuner(WaterfallTuner tuner) {
    _waterfallTuner =
        _swapDisposable(_waterfallTuner, tuner, (t) => t.dispose());
  }

  /// Test/host seam: clear a previously-registered waterfall tuner.
  @visibleForTesting
  void disableWaterfallTuner() {
    _waterfallTuner = _swapDisposable<WaterfallTuner>(
        _waterfallTuner, null, (t) => t.dispose());
  }

  ProviderFailoverAdvisor? _providerFailoverAdvisor;

  /// `null` by default — see [enableProviderFailoverAdvisor].
  ProviderFailoverAdvisor? get providerFailoverAdvisor =>
      _providerFailoverAdvisor;

  /// T143 — opt in to tracking consecutive load failures for
  /// [applyProviderFailover] to act on before the host's NEXT
  /// `initialize()` call. See [ProviderFailoverAdvisor]'s own doc comment
  /// for why this is a purely CURRENT-provider reliability signal, not
  /// [WaterfallTuner]'s cross-provider quality comparison.
  void enableProviderFailoverAdvisor(ProviderFailoverAdvisor advisor) {
    _providerFailoverAdvisor = _swapDisposable(
        _providerFailoverAdvisor, advisor, (a) => a.dispose());
  }

  /// Test/host seam: clear a previously-registered failover advisor.
  @visibleForTesting
  void disableProviderFailoverAdvisor() {
    _providerFailoverAdvisor = _swapDisposable<ProviderFailoverAdvisor>(
        _providerFailoverAdvisor, null, (a) => a.dispose());
  }

  /// T143 — apply [advisor]'s recommendation to [provider]: if
  /// [ProviderFailoverAdvisor.failingProvider] equals [provider] — i.e.
  /// [provider] is the SAME one whose consecutive failures actually
  /// tripped the streak — returns the other provider; otherwise returns
  /// [provider] unchanged. Call this LAST — after
  /// `pickProviderCohort`/`pickSessionProvider` — right before building
  /// the [AdConfig] passed to `initialize()`.
  ///
  /// Round-1 independent review (MAJOR) — checking only
  /// [ProviderFailoverAdvisor.shouldFailoverNextSession] (a bare bool)
  /// used to flip WHATEVER [provider] the caller passed, even if that
  /// caller's own earlier `pickProviderCohort`/`pickSessionProvider` had
  /// already independently picked the healthy provider — flipping it back
  /// to the one that just failed. Comparing against
  /// [ProviderFailoverAdvisor.circuitTrackedProvider] specifically fixes
  /// that: a candidate that is already the other (healthy) provider is
  /// left alone.
  ///
  /// Post-T208 audit fix (CONFIRMED bug) — this used to compare against
  /// [ProviderFailoverAdvisor.failingProvider], which is `null` for the
  /// whole `halfOpen` window (not just once fully `closed`), so every
  /// call here during `halfOpen` silently returned [provider] unchanged —
  /// reverting straight back to the previously-failing provider on pure
  /// elapsed time, with ZERO real verification it had recovered, and with
  /// [ProviderFailoverAdvisor.allowHalfOpenProbe]'s single-probe guard
  /// never consulted at all (the class had it, calling code just never
  /// used it). Routing `halfOpen` through `allowHalfOpenProbe` restores
  /// the single-probe design the class was actually built for: exactly
  /// ONE call gets to use the real provider again per half-open window: if
  /// it fails, [ProviderFailoverAdvisor]'s own event handling reopens the
  /// circuit for another full cooldown; if it succeeds, the circuit closes.
  ///
  /// Purely a decision helper: it never switches anything itself, never
  /// touches [advisor]'s own state beyond claiming the probe slot, and the
  /// SDK still only ever serves whichever provider ends up in the
  /// [AdConfig] the host builds from the result — no concurrent
  /// dual-adapter runtime exists or is needed here.
  AdProvider applyProviderFailover(
    AdProvider provider, {
    required ProviderFailoverAdvisor advisor,
  }) {
    if (advisor.circuitTrackedProvider != provider) return provider;
    final other =
        provider == AdProvider.admob ? AdProvider.appLovin : AdProvider.admob;
    switch (advisor.circuitState) {
      case ProviderCircuitState.open:
        return other;
      case ProviderCircuitState.halfOpen:
        return advisor.allowHalfOpenProbe() ? provider : other;
      case ProviderCircuitState.closed:
        return provider;
    }
  }

  /// T127 — flagship self-healing dual-provider runtime, OBSERVE-ONLY
  /// prototype (default OFF) — `null` unless the host app calls
  /// [enableSelfHealingObserver]. See [SelfHealingObserver] doc: it never
  /// switches providers, it only emits [AdSelfHealingObserveEvent] onto
  /// [events] reporting what a future auto-act version would have done.
  SelfHealingObserver? _selfHealingObserver;

  /// `null` by default — see [enableSelfHealingObserver].
  SelfHealingObserver? get selfHealingObserver => _selfHealingObserver;

  /// Opt in to the self-healing observer: starts watching [events] for a
  /// (format, placement) whose trailing fill-rate/eCPM data recommends the
  /// other provider, and reports it — never switches anything.
  ///
  /// Read [SelfHealingObserver]'s own doc comment before enabling this in
  /// production expecting it to eventually fire: given the current
  /// one-provider-per-install architecture, it cannot.
  void enableSelfHealingObserver(SelfHealingObserver observer) {
    _selfHealingObserver =
        _swapDisposable(_selfHealingObserver, observer, (o) => o.dispose());
  }

  /// Test/host seam: clear a previously-registered self-healing observer.
  @visibleForTesting
  void disableSelfHealingObserver() {
    _selfHealingObserver = _swapDisposable<SelfHealingObserver>(
        _selfHealingObserver, null, (o) => o.dispose());
  }

  /// T127 — the only way anything outside [AdManager] reaches [_emit]:
  /// reports a [WaterfallRecommendation] onto [events] as an
  /// [AdSelfHealingObserveEvent]. Purely observational — see that event's
  /// own doc for why this can never itself change which provider is active.
  void emitSelfHealingObservation(WaterfallRecommendation rec) {
    _emit(AdSelfHealingObserveEvent(
      providerTag: rec.currentProvider,
      type: rec.type,
      placement: rec.placement,
      wouldSwitchToProvider: rec.recommendedProvider,
      currentScore: rec.currentScore,
      recommendedScore: rec.recommendedScore,
    ));
  }

  /// T123 — opt-in on-device smart prefetch (default OFF) — `null` unless
  /// the host app calls [enableJourneyPrefetcher]. See [JourneyPrefetcher]
  /// doc: `notifySignal()` only ever calls the same public `loadX()` a host
  /// could call directly, so every existing safety/consent/VIP gate still
  /// applies unchanged.
  JourneyPrefetcher? _journeyPrefetcher;

  /// `null` by default — see [enableJourneyPrefetcher].
  JourneyPrefetcher? get journeyPrefetcher => _journeyPrefetcher;

  /// Opt in to the journey prefetcher.
  void enableJourneyPrefetcher(JourneyPrefetcher prefetcher) {
    _journeyPrefetcher =
        _swapDisposable(_journeyPrefetcher, prefetcher, (p) => p.dispose());
  }

  /// Test/host seam: clear a previously-registered journey prefetcher.
  @visibleForTesting
  void disableJourneyPrefetcher() {
    _journeyPrefetcher = _swapDisposable<JourneyPrefetcher>(
        _journeyPrefetcher, null, (p) => p.dispose());
  }

  int? _featureFlagsRevision;

  /// Applies a verified feature-flag payload. Invalid, expired, or stale
  /// payloads are rejected and leave the current configuration untouched.
  Future<bool> applySignedFeatureFlags(
    SignedFeatureFlags payload, {
    required String publicKeyBase64,
    DateTime? now,
  }) async {
    if (!await payload.verify(
        publicKeyBase64: publicKeyBase64,
        previousRevision: _featureFlagsRevision,
        now: now)) {
      return false;
    }
    _featureFlagsRevision = payload.revision;
    if (payload.flags['arbitrator'] == false) {
      disableArbitrator();
    }
    if (payload.flags['waterfallTuner'] == false) {
      disableWaterfallTuner();
    }
    if (payload.flags['journeyPrefetcher'] == false) {
      disableJourneyPrefetcher();
    }
    if (payload.flags['selfHealingObserver'] == false) {
      disableSelfHealingObserver();
    }
    SafeLogger.d(
        _tag, () => 'feature flags applied revision=${payload.revision}');
    return true;
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
  ///
  /// Round-31 audit fix — this used to also dispose [_waterfallTuner],
  /// [_selfHealingObserver] and [_journeyPrefetcher] (copy-pasted from
  /// `destroy()`, where tearing down all four together is correct because
  /// that IS a full SDK teardown). Those three are independent opt-in
  /// features with their own `enable*`/`disable*` pair each — a host
  /// disabling only the baseline monitor must not silently kill the other
  /// three with no warning.
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
      // T187
      pendingRevenueChecks: _revenueIntegrityLedger?.pendingCount,
      recentRevenueIntegrityIncidents: incidentRecorder.entries
          .where((e) => e.label.startsWith('revenue_integrity_missing:'))
          .length,
    );
  }

  /// Observe-only analysis of persisted revenue events.
  List<RevenueAnomaly> revenueAnomalies({int minimumSamples = 5}) =>
      RevenueAnomalyDetector(minimumSamples: minimumSamples)
          .analyze(_eventLog?.entries ?? const <Map<String, dynamic>>[]);

  /// Exports a privacy-safe, bounded diagnostics snapshot for support tools.
  /// No preferences, credentials, or raw compliance-log metadata are included.
  Future<String> exportSafeDiagnostics({int maxBytes = 65536}) =>
      diagnostics().toSafeJsonString(maxBytes: maxBytes);

  /// T200 — clears SDK-owned persisted data for a privacy/data-erasure
  /// request. Unlike `AdPreferences.clearAllData()` (which wipes the
  /// ENTIRE shared `SharedPreferences` instance, including any key a
  /// host app or a different plugin stored in the same namespace), this
  /// only ever touches keys this SDK itself owns — across BOTH storage
  /// backends it actually uses (`SharedPreferences` via `AdPreferences`,
  /// and `flutter_secure_storage` for VIP entitlements).
  ///
  /// [scope] defaults to [SdkDataErasureScope.everythingExceptEntitlements]
  /// — safety counters, consent settings, compliance/analytics history,
  /// remote-config cache, experiment id. VIP entitlements are left
  /// completely untouched at this scope.
  ///
  /// [SdkDataErasureScope.allIncludingEntitlements] ALSO erases every
  /// VIP-entitlement key across both backends (VIP entries, redeemed-key
  /// ledger, first-install grace flag, migration flags, revocation
  /// cache, legacy GAID list) — and requires [confirmedEntitlementErasure]:
  /// `true`. Passing that scope without it throws an [ArgumentError]
  /// rather than silently downgrading the scope: this permanently
  /// deletes VIP entitlements a user may have paid real money for, so a
  /// caller must say so explicitly, not by accident.
  ///
  /// Deliberately does NOT touch the on-device Ed25519 compliance-signing
  /// key (`signComplianceReport`/`signJsonPayload`'s shared key,
  /// `compliance_signing.dart`) at either scope — it carries no personal
  /// data (a device-generated keypair with no identifying content), and
  /// erasing it would only cost future compliance-report/incident-bundle
  /// exports their key continuity for no privacy benefit.
  Future<void> clearSdkData({
    SdkDataErasureScope scope =
        SdkDataErasureScope.everythingExceptEntitlements,
    bool confirmedEntitlementErasure = false,
  }) async {
    if (scope == SdkDataErasureScope.allIncludingEntitlements &&
        !confirmedEntitlementErasure) {
      throw ArgumentError(
          'SdkDataErasureScope.allIncludingEntitlements requires '
          'confirmedEntitlementErasure: true — this permanently deletes '
          'VIP entitlements a user may have paid for.');
    }
    final prefs = await AdPreferences.getInstance();
    await prefs.clearSdkData(
      scope: scope,
      confirmedEntitlementErasure: confirmedEntitlementErasure,
    );
    if (scope == SdkDataErasureScope.allIncludingEntitlements) {
      final vip = _vipManager;
      if (vip != null) {
        // SDK is live — also clears the in-memory list and refreshes the
        // reactive activeListenable immediately (see
        // eraseAllEntitlementData's doc comment for why this matters).
        await vip.eraseAllEntitlementData();
      } else {
        await VipManager.eraseSecureEntitlementStorage(prefs);
      }
      await (debugFirstInstallGuardFactory?.call() ?? FirstInstallGuard())
          .erase();
    }
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
          loadInterstitial, loadTimeout, _adapter!.interstitialSlot),
      await _selfCheckLoad('Rewarded load', AdSlotType.rewarded,
          loadRewardedAd, loadTimeout, _adapter!.rewardedSlot),
      await _selfCheckLoad('App Open load', AdSlotType.appOpen,
          () => loadAppOpenAd(), loadTimeout, _adapter!.appOpenSlot),
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

  /// T193 — readiness-first, not event-only. Some `load()` calls
  /// short-circuit without ever emitting a fresh `AdLoadEvent` when the
  /// slot already holds a fresh, still-ready ad (e.g.
  /// `AdMobAdapter.loadInterstitial`'s "fresh — keep it" early return) —
  /// the pre-fix version here waited ONLY for a new event, so a genuinely
  /// healthy, already-preloaded slot timed out and reported a false FAIL.
  ///
  /// Watching [slot]'s own state directly instead of the event stream
  /// fixes this for free and needs no type/generation-matching either
  /// way: an already-`ready` slot is caught by the immediate check below,
  /// a slot already in `cooldown` (backoff blocked this very `load()`
  /// call from attempting anything) is reported immediately too instead
  /// of silently timing out, and a genuinely in-flight load is caught by
  /// the listener once it resolves.
  Future<SelfCheckItem> _selfCheckLoad(String name, AdSlotType type,
      Future<void> Function() load, Duration timeout, AdSlot slot) async {
    await load();
    if (slot.isReady) {
      return SelfCheckItem(
          name, SelfCheckStatus.pass, 'already ready (preloaded)');
    }
    if (slot.isCooldown) {
      return SelfCheckItem(name, SelfCheckStatus.fail,
          '$name: slot in cooldown (last error code=${slot.lastErrorCode ?? "?"})');
    }
    final completer = Completer<bool>();
    void onStateChange() {
      if (completer.isCompleted) return;
      if (slot.isReady) completer.complete(true);
      if (slot.isCooldown) completer.complete(false);
    }

    slot.state.addListener(onStateChange);
    final success =
        await completer.future.timeout(timeout, onTimeout: () => false);
    slot.state.removeListener(onStateChange);
    return SelfCheckItem(
      name,
      success ? SelfCheckStatus.pass : SelfCheckStatus.fail,
      success
          ? null
          : '$name: slot never reached ready within ${timeout.inSeconds}s '
              '(state=${slot.value.name})',
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

  /// Override the [FirstInstallGuard] `initialize()` builds, so a test can
  /// drive the anti-bypass read — including the case where it never answers.
  ///
  /// Round-23 QC (reviewer C, MINOR) — the timeout branch is the whole point of
  /// the fix and is otherwise unreachable: the real guard reads the iOS
  /// Keychain through `flutter_secure_storage`, which in a unit test fails fast
  /// rather than blocking.
  @visibleForTesting
  static FirstInstallGuard Function()? debugFirstInstallGuardFactory;

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

  /// T151 — lets a demo/test reach the real, currently-active event log
  /// (or discover there isn't one yet) to inject a raw entry via
  /// [AdEventLog.debugInjectRawEntry], so [diagnostics] can be exercised
  /// end to end against a malformed persisted entry instead of only
  /// calling [AdDiagnostics.lastWaterfallBySlotFrom] directly.
  @visibleForTesting
  AdEventLog? get debugEventLog => _eventLog;

  /// T128 — flagship proof-of-compliance: every time [showAppOpenAd]'s
  /// `bypassSafety` or [showRewardedAd]'s `bypassVipGuard` back door was
  /// actually exercised, across the whole process — deliberately NOT reset
  /// by `destroy()`/re-`initialize()` (unlike [_eventLog]), since a provider
  /// switch mid-session is exactly the kind of event this audit trail
  /// should still cover. Export via [exportSignedBypassAuditTrail].
  final BypassAuditTrail bypassAuditTrail = BypassAuditTrail();

  /// Signs [bypassAuditTrail]'s current contents with the same on-device
  /// Ed25519 key as [exportSignedComplianceReport] — verify with
  /// `dart run tool/bypass_audit_replay.dart <path>` (same tool family as
  /// `tool/incident_replay.dart`/`tool/verify_compliance_report.dart`).
  Future<SignedPayload> exportSignedBypassAuditTrail() =>
      signBypassAuditTrail(bypassAuditTrail);

  /// T144 — same "not reset by destroy()" reasoning as [bypassAuditTrail]:
  /// a provider switch mid-session is exactly the kind of event a dispute
  /// export should still be able to explain. Export via
  /// [exportSignedIncidentBundle]. Nothing in the SDK calls `.record()` on
  /// this yet — it's exposed so a host (or a future ticket) can feed it at
  /// its own state-transition points; T144's own scope is only the export
  /// side, not wiring up recording call sites.
  final IncidentRecorder incidentRecorder = IncidentRecorder();

  /// Signs [incidentRecorder]'s current buffer with the same on-device
  /// Ed25519 key as [exportSignedComplianceReport] — verify with
  /// `verifySignedJsonPayload` or `dart run tool/incident_replay.dart`.
  ///
  /// Safe to call before [initialize] — [IncidentBundle.capture] needs an
  /// [AdConfig] only for its redacted config fingerprint, so an empty
  /// fingerprint is used instead of throwing.
  Future<SignedPayload> exportSignedIncidentBundle() {
    final config = _config;
    final bundle = config == null
        ? IncidentBundle(
            entries: incidentRecorder.entries,
            configFingerprint: const {},
            generatedAtMs: DateTime.now().millisecondsSinceEpoch,
          )
        : IncidentBundle.capture(incidentRecorder, config);
    return signIncidentBundle(bundle);
  }

  /// T144 — all 3 signed exports above, bundled into one artifact so a host
  /// can hand a partner/reviewer a single file during a dispute/appeal
  /// instead of calling 3 methods and gluing the JSON together itself. Pure
  /// aggregation — no new signing/redaction logic of its own.
  Future<DisputeKit> exportDisputeKit({DateTime? from, DateTime? to}) async {
    return DisputeKit(
      compliance: await exportSignedComplianceReport(from: from, to: to),
      bypassAuditTrail: await exportSignedBypassAuditTrail(),
      incidentBundle: await exportSignedIncidentBundle(),
    );
  }

  /// T129 — flagship Monetization Digital Twin (v0, daily-cap axis only —
  /// see [MonetizationDigitalTwin]'s class doc for why this is deliberately
  /// narrower than the full ticket). Builds a fresh, read-only twin from the
  /// current compliance-log history; `null` before the SDK has ever
  /// initialised (no event log exists yet to replay).
  MonetizationDigitalTwin? buildMonetizationDigitalTwin() {
    final log = _eventLog;
    if (log == null) return null;
    return MonetizationDigitalTwin(log.entries);
  }

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

  /// Round-25 QC round 11 — test seam. The real backoff starts at 5s, and the
  /// teardown/retry ordering tests have to out-wait it; with the event-stream
  /// close now capped at 2s they can no longer hold a teardown open that long,
  /// and a fixed `Future.delayed(5.2s)` was flaky under load anyway (the first
  /// attempt's own VIP/UMP work eats into it). Overriding the schedule keeps
  /// those tests about the ORDERING they actually pin instead of wall clock.
  @visibleForTesting
  static List<Duration>? debugInitRetryDelays;

  /// Test seam — the delay the most recent init retry was actually armed with,
  /// after [debugInitRetryDelays] is capped. Lets a test prove the cap without
  /// sitting through a real 30s backoff.
  @visibleForTesting
  static Duration? debugLastInitRetryDelay;

  static const List<Duration> _kInitRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  int _initRetryAttempts = 0;
  Timer? _initRetryTimer;

  /// The `onComplete` of the caller whose failed attempt armed
  /// [_initRetryTimer]. It is held here, and not only captured inside the
  /// timer's closure, because both a fresh `initialize()` and `destroy()`
  /// cancel that timer outright — and cancelling a `Timer` throws its closure
  /// away, the host callback with it.
  ///
  /// Round-25 QC round 8 (`agy`, MAJOR): the caller was then never answered at
  /// all, neither `true` nor `false`. A splash awaiting that callback sat
  /// there until its own hard-cap timer fired (or, in a host without one,
  /// forever) even though the SDK had meanwhile come up fine.
  void Function(bool success, String gaid)? _pendingRetryOnComplete;

  @visibleForTesting
  bool get debugPendingRetryCallback => _pendingRetryOnComplete != null;
  bool _isInternalInitRetryCall = false;
  int _initGen = 0;

  @visibleForTesting
  bool get debugInitRetryScheduled => _initRetryTimer?.isActive ?? false;

  /// T132 — regression seam: simulates a `destroy()`+`initialize()` cycle
  /// completing (bumping [_initGen]) while some other async op captured an
  /// earlier generation and is still in flight, without the weight of a
  /// real adapter init.
  @visibleForTesting
  void debugBumpInitGen() => _initGen++;

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
    // Any deliberate gate write settles the round-11 debt — see
    // [_pessimisticGateClose]. The one site that owes a reopen re-arms it
    // immediately after calling this.
    _pessimisticGateClose = false;
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

  /// Round-26 audit (MAJOR, claude), fix attempt 3 — narrow, self-contained,
  /// and deliberately NOT the same mechanism as [_pessimisticGateClose].
  /// That flag means something specific (round 11): "a QUEUED apply result
  /// whose own restrictiveness is not yet known, guess-closed until it runs
  /// or [_recoverConsentGate] re-derives the truth from the device." This is
  /// a different problem: `applyConsentToProviders()` (called from
  /// [setConsent]) applies to AppLovin synchronously but AWAITS AdMob's
  /// `updateRequestConfiguration` — the new consent value is already fully
  /// decided, there is nothing to "recover" or "guess", the write to the
  /// providers is just not finished landing yet. A concurrent load firing in
  /// that window would go out under AdMob's OLD global RequestConfiguration.
  ///
  /// Set/cleared by [setConsent] around that one `await`, in a `finally` —
  /// no epoch, no debt, no recovery: it cannot be "left shut", because
  /// nothing persists it past that single call frame.
  bool _consentProviderApplyInFlight = false;

  /// See [_canRequestAds] / [_footgunBlocked] / [_consentProviderApplyInFlight].
  bool get canRequestAds =>
      _canRequestAds && !_footgunBlocked && !_consentProviderApplyInFlight;

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
  /// The one answer to "may this adapter present a fullscreen ad **right
  /// now**". Returns a reason to skip, or `null` to proceed.
  ///
  /// Round-25 sweep (post-QC-22) — rounds 12 through 22 were every one of them
  /// the same shape: a guard read before an `await`, an act performed after it.
  /// Each round the fix was a fresh hand-written check at whichever site the
  /// reviewer happened to probe, so the guards ended up in three different
  /// styles and the next unswept branch was always one round away. This is the
  /// single place those three facts are asked about now, and every fullscreen
  /// show path asks it immediately before presenting:
  ///
  ///  * a teardown started (`destroy()` is dismantling the session),
  ///  * the adapter was swapped (a `destroy()` + re-`initialize()` while `ad`
  ///    was captured before an await — showing on it drives a disposed native
  ///    channel),
  ///  * consent was withdrawn (an impression served after the user said no is
  ///    the single outcome this SDK exists to prevent).
  ///
  /// Deliberately NOT here: the fullscreen mutex ([_fullscreenBusyReason]), the
  /// safety caps and the VIP suppression. Those have per-path semantics — the
  /// splash App Open bypasses safety, the VIP extension flow bypasses VIP — so
  /// folding them in would make this helper lie at three of its four call
  /// sites. Their own checks stay where they are.
  ///
  /// At three of the four call sites there is no `await` between the entry gate
  /// and the show today, so the call is redundant *today*. That is the point:
  /// the next person to add an await there — an on-demand load, a dialog, a
  /// mediation hop — inherits the guard instead of re-opening the hole.
  /// `test/show_paths_guard_test.dart` fails if a show path stops calling it.
  String? _presentBlockedReason(AdProviderAdapter ad) {
    if (_destroyInFlight != null) return 'a teardown is in flight';
    if (!identical(_adapter, ad)) {
      return 'the SDK was torn down or re-initialised';
    }
    if (!canRequestAds) return 'consent was withdrawn';
    return null;
  }

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

    // T168 — same class of gap `umpFormOnScreen` above closes for the
    // native UMP form: a host's own custom overlay (e.g. a manual
    // `Overlay.of(context).insert(...)`, not a `PopupRoute` through a
    // `Navigator`) is invisible to `isDialogOnTop` below. Opt-in and
    // host-declared via `markCustomOverlayOnScreen` — see that function's
    // doc comment. Must sit here, ahead of the `ad == null` early return
    // below, for the same reason `umpFormOnScreen` does: a host can show
    // its own overlay before `AdManager().initialize()` has ever run (no
    // adapter yet), and this guard has to hold during that window too —
    // that early return used to make it a no-op until init actually
    // finished (codex review, T168 round 1).
    if (customOverlayOnScreen.value) {
      return 'a custom host overlay is on screen';
    }

    // Round-25 QC round 13 (`codex`, MAJOR) — the teardown belongs HERE, in the
    // one gate every fullscreen path re-reads, not only at each show method's
    // entry. `showRewardedAd` checks `_teardownBlocksShow` up front, then awaits
    // `_loadRewardedOnDemand`; a `destroy()` starting inside that await used to
    // be invisible to the post-load re-check, which consulted this getter alone.
    // codex's probe watched a rewarded ad play and pay out its reward while
    // `_destroyInFlight != null`. Folding it in covers all four ad types, every
    // post-await re-check, and any fifth type added later by construction.
    if (_destroyInFlight != null) return 'a teardown is in flight';
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
  /// [_fullscreenBusyReason]'s seven inputs changes: the four fullscreen ad
  /// slots (via [_attachFullscreenBusySlotListeners], re-wired on every
  /// adapter swap by the `_adapter` setter above), [AdLoadingDialog]'s,
  /// [AdScreenRouteLogger]'s, and (T168) [customOverlayOnScreen]'s own
  /// notifiers (wired once in [_internal]).
  final ValueNotifier<bool> fullscreenBusy = ValueNotifier<bool>(false);

  void _recomputeFullscreenBusy() {
    fullscreenBusy.value = _fullscreenBusyReason != null;
    _scheduleStateSnapshotRecompute();
  }

  // ─── T109 — AdSdkStateSnapshot ─────────────────────────────────────────────
  //
  // Combines isInitialised/canRequestAds/isOffline/isVipActive/fullscreenBusy
  // into one ValueListenable so a host doesn't have to hand-wire five
  // separate notifiers. Every source notifier here already lives for the
  // whole process (this is a singleton) — the ONLY per-session-lived source
  // is VIP's activeListenable, already subscribed/unsubscribed correctly
  // around every init/destroy cycle by _onVipActiveChanged's own callers
  // (see `vip.activeListenable.addListener(_onVipActiveChanged)` at init and
  // the matching `removeListener` in destroy() / before a fresh init) — this
  // getter just hangs an extra recompute off that existing callback instead
  // of adding its own subscription.

  AdSdkStateSnapshot _computeStateSnapshot() => AdSdkStateSnapshot(
        isInitialised: isInitialised,
        canRequestAds: canRequestAds,
        isOffline: isOfflineListenable.value,
        isVipActive: _vipManager?.isActive ?? false,
        fullscreenBusy: fullscreenBusy.value,
      );

  late final ValueNotifier<AdSdkStateSnapshot> _stateSnapshotNotifier =
      ValueNotifier<AdSdkStateSnapshot>(_computeStateSnapshot());

  bool _stateSnapshotRecomputeScheduled = false;

  void _scheduleStateSnapshotRecompute() {
    // Coalesces bursts (e.g. offline flips AND canRequestAds flips in the
    // same synchronous callback) into a single listener notification instead
    // of one per source.
    if (_stateSnapshotRecomputeScheduled) return;
    _stateSnapshotRecomputeScheduled = true;
    scheduleMicrotask(() {
      _stateSnapshotRecomputeScheduled = false;
      final next = _computeStateSnapshot();
      if (next != _stateSnapshotNotifier.value) {
        _stateSnapshotNotifier.value = next;
      }
    });
  }

  /// T109 — one `ValueListenable` combining init/consent/offline/VIP/
  /// fullscreen-busy state, coalesced onto a microtask so a burst of
  /// several source changes in the same synchronous callback only notifies
  /// listeners once. Read `.value` for the current snapshot immediately, or
  /// wrap in a `ValueListenableBuilder`/`addListener` to react to changes.
  ValueListenable<AdSdkStateSnapshot> get stateSnapshot =>
      _stateSnapshotNotifier;

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
    final event = AdSkipEvent(
      providerTag: providerTag ?? _adapter?.tag ?? '[SDK]',
      type: type,
      placement: placement,
      action: action,
      reason: reason,
    );
    // T119 — every one of this method's ~50 call sites already carries the
    // exact reason a load/show attempt was gated; the only thing missing was
    // somewhere to keep the latest one per slot for a host (or support) to
    // ask "why isn't this ad showing?" without turning on verbose logging
    // first. See [explainLastSkip].
    _lastSkipByType[type] = event;
    _emit(event);
  }

  /// T119 — per-slot snapshot of the most recent [_emitSkip] call, read by
  /// [explainLastSkip]. Deliberately NOT cleared by [destroy] — a stale
  /// answer from the previous session (until the next real skip overwrites
  /// it) is a display quirk, not a correctness issue, and clearing it here
  /// would mean touching `destroy()`'s lifecycle for a purely diagnostic
  /// feature.
  final Map<AdSlotType, AdSkipEvent> _lastSkipByType = {};

  /// Test-only: [_lastSkipByType] persists across the whole process
  /// (deliberately not cleared by [destroy], see [explainLastSkip]'s doc),
  /// which makes it test-order-dependent in a file exercising many slots
  /// against the same singleton. Tests that care about a slot's *initial*
  /// (never-skipped) state should call this first.
  @visibleForTesting
  void debugResetLastSkip() => _lastSkipByType.clear();

  /// T119 — human-readable answer to the single most common ad-SDK support
  /// question: "why isn't this ad showing?" Reflects the most recent
  /// load/show attempt for [type] that an internal gate skipped (VIP,
  /// consent, cap, cooldown, offline, dry-run, teardown-in-flight, ...) —
  /// `null` if nothing has ever been skipped for [type] this session, or if
  /// the most recent attempt actually went through.
  ///
  /// The reason is the exact machine-readable code already carried by
  /// [AdSkipEvent.reason] (see that field's doc for known values), spaced
  /// out for readability — deliberately not a hand-maintained
  /// code-to-sentence table, which would silently go stale the next time a
  /// call site adds a new reason code.
  String? explainLastSkip(AdSlotType type) {
    final skip = _lastSkipByType[type];
    if (skip == null) return null;
    final reason = skip.reason.replaceAll(RegExp('[_-]'), ' ');
    return '${type.name} ${skip.action} skipped: $reason';
  }

  void _armLoadWatchdog(String label, AdSlot slot, Duration timeout) =>
      slot.armLoadWatchdog(label, timeout);

  /// Test seam for the consent gate.
  @visibleForTesting
  set debugCanRequestAds(bool v) => _updateCanRequestAds(v);

  /// Test seam — the result the running drain is handing out, or `null` when
  /// no drain is running. See [_drainingInitResult].
  @visibleForTesting
  bool? get debugDrainingInitResult => _drainingInitResult;

  /// Test seam — the session epoch a UMP round trip binds itself to. Bumped by
  /// [destroy]; see [_applyUmpConsentResult].
  @visibleForTesting
  int get debugConsentSessionEpoch => _consentSessionEpoch;

  /// Test seam — applies a UMP result exactly as a real round trip's tail does,
  /// without a UMP channel. [session] is what binds it to a session.
  @visibleForTesting
  Future<void> debugApplyUmpConsentResult(UmpConsentResult result,
          {int? session}) =>
      _applyUmpConsentResult(result, session: session);

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

  /// One native load per fullscreen slot at a time. Concurrent callers join
  /// the existing future; independent slots remain fully parallel.
  final Map<AdSlotType, Future<void>> _inFlightAdLoads = {};
  final Map<AdSlotType, int> _adLoadGenerations = {};
  final List<void Function(bool)> _appOpenLoadCallbacks = [];

  Future<void> _coalesceAppOpenLoad(
      AdProviderAdapter ad, void Function(bool)? callback) {
    if (callback != null) _appOpenLoadCallbacks.add(callback);
    final existing = _inFlightAdLoads[AdSlotType.appOpen];
    if (existing != null) return existing;
    final generation = (_adLoadGenerations[AdSlotType.appOpen] ?? 0) + 1;
    _adLoadGenerations[AdSlotType.appOpen] = generation;
    final completer = Completer<void>();
    final started = completer.future;
    bool? loadedResult;
    var adapterFutureDone = false;
    var callbackReceived = false;
    void dispatchCallbacks() {
      if (!adapterFutureDone || !callbackReceived) return;
      // Post-T218 audit fix (CONFIRMED race) — this used to only clear the
      // callback queue here and remove the in-flight marker separately, a
      // whole microtask later, in `.whenComplete()` below (`.then()`'s
      // callback body — which calls this function — runs synchronously,
      // but its own completion is only OBSERVED by `.whenComplete()` on
      // the next microtask). A caller whose own dispatched callback
      // synchronously starts ANOTHER app-open load (a common "retry on
      // failure" pattern) would run inside that gap: `_inFlightAdLoads`
      // still held this (already fully resolved, never dispatching again)
      // future, so the reentrant call silently "joined" it — its own
      // Future still resolved eventually, but its callback was queued
      // into a slot nothing would ever dispatch to again. Removing the
      // marker HERE, before any callback runs (not after all of them,
      // in a separate later step), means a reentrant call from inside one
      // of these callbacks sees a clean slate and correctly starts a
      // fresh load instead.
      if (identical(_inFlightAdLoads[AdSlotType.appOpen], started) &&
          _adLoadGenerations[AdSlotType.appOpen] == generation) {
        _inFlightAdLoads.remove(AdSlotType.appOpen);
      }
      final callbacks = List<void Function(bool)>.from(_appOpenLoadCallbacks);
      _appOpenLoadCallbacks.clear();
      for (final cb in callbacks) {
        try {
          cb(loadedResult ?? false);
        } catch (e) {
          SafeLogger.w(_tag, 'app-open load callback threw: $e');
        }
      }
    }

    // Publish the future before invoking the adapter: a synchronous fake or
    // native bridge callback must not race the map insertion.
    _inFlightAdLoads[AdSlotType.appOpen] = started;
    unawaited(ad.loadAppOpen(onAdLoaded: (loaded) {
      loadedResult = loaded;
      callbackReceived = true;
      dispatchCallbacks();
    }).then((_) {
      adapterFutureDone = true;
      if (!completer.isCompleted) completer.complete();
      dispatchCallbacks();
    }).catchError((Object error, StackTrace stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    }).whenComplete(() {
      if (identical(_inFlightAdLoads[AdSlotType.appOpen], started) &&
          _adLoadGenerations[AdSlotType.appOpen] == generation &&
          callbackReceived) {
        _inFlightAdLoads.remove(AdSlotType.appOpen);
        _appOpenLoadCallbacks.clear();
      }
    }));
    return started;
  }

  Future<void> _coalesceAdLoad(
      AdSlotType type, Future<void> Function() operation) {
    final existing = _inFlightAdLoads[type];
    if (existing != null) return existing;
    final generation = (_adLoadGenerations[type] ?? 0) + 1;
    _adLoadGenerations[type] = generation;
    late final Future<void> started;
    started = operation().whenComplete(() {
      if (identical(_inFlightAdLoads[type], started) &&
          _adLoadGenerations[type] == generation) {
        _inFlightAdLoads.remove(type);
      }
    });
    _inFlightAdLoads[type] = started;
    return started;
  }

  void _invalidateCoalescedLoads() {
    for (final type in _inFlightAdLoads.keys.toList()) {
      _adLoadGenerations[type] = (_adLoadGenerations[type] ?? 0) + 1;
    }
    _inFlightAdLoads.clear();
    _appOpenLoadCallbacks.clear();
  }

  /// T149 — lets an on-device test force [_umpAnswered] to `false` without
  /// a real unanswered EEA session, so the reconnect/backstop UMP-retry
  /// branches (gated on `!_umpAnswered`) can be reached deterministically.
  @visibleForTesting
  set debugLastUmpResult(UmpConsentResult? r) => _lastUmpResult = r;

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

  /// T149 — lets a test drive the periodic-backstop/reconnect call sites'
  /// `if (_umpFormAbandoned)` branch (their `runZonedGuarded` crash guard)
  /// without first having to reproduce a real abandoned-form sequence.
  @visibleForTesting
  set debugUmpFormAbandoned(bool v) => _umpFormAbandoned = v;

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

  /// Test seam — whether the app-lifecycle observer (App Open on resume, ad
  /// pause/resume) is currently attached. `destroy()`'s teardown detaches it.
  @visibleForTesting
  bool get debugLifecycleObserverAttached => _isObserverAdded;

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

  /// Round-26 audit (MAJOR, claude) — the scheduled show below used to be a
  /// bare `Future.delayed` with nothing keeping a handle on it. If
  /// `destroy()` ran and a fresh `initialize()` (a different `AdConfig`, e.g.
  /// a QA build vs. production) happened inside that delay window, the old
  /// closure — capturing the OLD `cfg`/`mgr` — still fired and applied the
  /// stale config (including `testDeviceIds`) on top of the new session.
  /// Holding the `Timer` here lets `destroy()` cancel it outright instead of
  /// just resetting the flag that guards re-scheduling.
  Timer? _consentDialogTimer;

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
    _consentDialogTimer?.cancel();
    _consentDialogTimer = Timer(delay, () async {
      _consentDialogTimer = null;
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
    SafeLogger.d(
        _tag, () => 'GAID resolved (present=${_currentDeviceGAID.isNotEmpty})');
  }

  /// First-init: import VIP GAIDs from `config.vipDeviceGaids` (release
  /// builds only). Only entries whose GAID matches THIS device (per
  /// [_currentDeviceGAID]) are persisted as active VIP — matching 1.x
  /// behaviour exactly. No-op once already run (`isAddVIPMemberFirstInitSuccess`).
  ///
  /// [isDebug] exists only so a test can reach the body at all — every unit
  /// test runs under `kDebugMode`, which this method returns on. Same shape as
  /// `initialize()`'s `isRelease` parameter.
  Future<void> _applyConfigVipGaidWhitelist(
      AdConfig config, VipManager vip, AdPreferences prefs,
      {bool isDebug = kDebugMode}) async {
    if (isDebug || config.vipDeviceGaids.isEmpty) return;
    // Round-23 QC (reviewer C, MINOR) — this used to be a plain one-shot: flag
    // set, never granted again. But the grant below asks for 50 years and
    // `VipManager` clamps every entry to `AdConfig.maxVipStackDuration` (~90
    // days), so a whitelisted device silently fell out of VIP after 90 days and
    // the flag made that permanent — the internal/QA devices this list exists
    // for had to reinstall the app to get it back. Re-grant once the window has
    // actually run out; nothing else changes, the device is still on the host's
    // own whitelist, which is all the grant ever asserted.
    if (prefs.isAddVIPMemberFirstInitSuccess() && vip.isActive) return;
    final myGaid = _currentDeviceGAID.trim().toUpperCase();
    for (final gaid in config.vipDeviceGaids) {
      if (gaid.trim().isEmpty) continue;
      if (gaid.trim().toUpperCase() != myGaid) continue;
      await vip.addVip(
        key: 'CONFIG_${gaid.trim()}',
        duration: const Duration(days: 365 * 50),
      );
    }
    // Round-37 QC (reviewer B, MAJOR) — `addVip` above can land on a manager
    // `destroy()` disposed while this `await` was in flight; its own `_save()`
    // already drops the write for that reason (round 18), but nothing here
    // stopped the flag below from being marked anyway — a config-whitelisted
    // device silently lost the grant this very call was supposed to give it,
    // permanently, since this flag is one-shot. Same rule as the first-install
    // grace block right below: the flag is set only once the grant actually
    // landed.
    if (vip.isDisposed) {
      SafeLogger.w(
          _tag,
          'GAID whitelist grant abandoned (destroy() mid-write) — not marking '
          'the one-shot flag over a dropped grant');
      return;
    }
    if (!prefs.isAddVIPMemberFirstInitSuccess()) {
      await prefs.addVIPMemberFirstInitSuccess();
    }
  }

  @visibleForTesting
  Future<void> debugApplyConfigVipGaidWhitelist(
    AdConfig config,
    VipManager vip,
    AdPreferences prefs, {
    required String deviceGaid,
  }) {
    _currentDeviceGAID = deviceGaid;
    return _applyConfigVipGaidWhitelist(config, vip, prefs, isDebug: false);
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
    // T137 — optional: when set (and remoteSafetyProvider is also set),
    // automatically calls refreshRemoteSafetyParams() on this schedule in
    // addition to the one-time fetch above. `null` (default) keeps the
    // original behavior — no automatic re-fetch, host calls
    // refreshRemoteSafetyParams() itself on whatever schedule it wants.
    Duration? remoteSafetyAutoRefreshInterval,
    @visibleForTesting bool isRelease = kReleaseMode,
  }) async {
    // T136 (round 2, MAJOR #4 in independent review) — captured and
    // cleared as the very first synchronous step, before any `await`,
    // because `pickSessionProvider()` is required to run synchronously
    // right before this call: whatever it just set belongs to THIS
    // attempt only. Without this, a pending decision left dangling by an
    // earlier attempt that threw or got superseded before reaching the
    // reconcile point further down could get wrongly attributed to a
    // LATER, unrelated session's VIP status. Threaded through as a local
    // all the way to `_reconcileProviderExplorationSlot` — never read back
    // from the field itself.
    final pendingExplorationAtMs = _pendingExplorationCommitAtMs;
    _pendingExplorationCommitAtMs = null;

    // Read + clear the internal-retry flag before the early-return guard —
    // otherwise a retry timer firing while another call already holds
    // `_isInitializing` leaves the flag stuck `true` forever (this call
    // returns without ever reaching the reset below), and the next
    // legitimate host-initiated call gets misclassified as an internal
    // retry and skips its retry-budget reset.
    final isInternalRetry = _isInternalInitRetryCall;
    _isInternalInitRetryCall = false;
    // Round-25 QC round 7 (`codex` MAJOR, `agy` MAJOR) — see [destroy]. A
    // teardown is mid-await: building a session now means the rest of that
    // teardown gets applied to it (adapter disposed, lifecycle observer
    // removed). Wait it out; the host asked for both, in this order, and this
    // is the order it gets. Deliberately before the duplicate guard below, and
    // deliberately not an `await` at all when no teardown is running — a
    // callback that re-enters `initialize()` from inside a drain is still
    // answered synchronously.
    final teardown = _destroyInFlight;
    if (teardown != null) {
      SafeLogger.w(
          _tag,
          'initialize() called while destroy() is still tearing down — '
          'waiting for the teardown to finish before starting a new session');
      await teardown;
    }
    // Guard so concurrent calls during a teardown-then-reinit cycle can't
    // slip past `_disposeAdapter`'s await and leak two adapters.
    if (_isInitializing) {
      final draining = _drainingInitResult;
      if (draining != null) {
        // Called from inside a host callback this very drain is invoking: the
        // in-flight attempt's result is already known, so hand it over now.
        // Parking here is what stranded callers past round 5's pass cap.
        SafeLogger.w(
            _tag,
            'initialize called from inside an onComplete — answering with the '
            'result being delivered ($draining) instead of parking');
        try {
          onComplete(draining, _currentDeviceGAID);
        } catch (e, st) {
          SafeLogger.e(_tag, 'host onComplete($draining) threw: $e\n$st');
        }
        return;
      }
      if (_queuedInitCallbacks.length >= _maxQueuedInitCallbacks) {
        SafeLogger.w(
            _tag,
            'initialize already in progress and $_maxQueuedInitCallbacks '
            'callers are already parked — this one is told false immediately');
        try {
          onComplete(false, _currentDeviceGAID);
        } catch (e, st) {
          SafeLogger.e(_tag, 'host onComplete(false) threw: $e\n$st');
        }
        return;
      }
      SafeLogger.w(
          _tag,
          'initialize already in progress — this caller is parked and will be '
          'told the in-flight result (see _queuedInitCallbacks)');
      _queuedInitCallbacks.add(onComplete);
      return;
    }
    _isInitializing = true;
    final initGen = ++_initGen;
    if (!isInternalRetry) {
      // A fresh, host-initiated call resets the auto-retry budget — otherwise
      // a legitimate manual retry right after the internal budget was
      // exhausted would look like it's still "out of retries".
      _initRetryAttempts = 0;
      _initRetryTimer?.cancel();
      _initRetryTimer = null;
      // Round-25 QC round 8 (`agy`, MAJOR) — the timer just cancelled was
      // holding the previous caller's `onComplete` (see
      // [_pendingRetryOnComplete]). Park it on this attempt's queue rather
      // than dropping it: this attempt drains the queue with its real result,
      // so a manual "Retry" that succeeds answers `true` to the caller that
      // had already given up, and a manual retry that fails answers `false`.
      final stranded = _pendingRetryOnComplete;
      _pendingRetryOnComplete = null;
      if (stranded != null) {
        if (_queuedInitCallbacks.length >= _maxQueuedInitCallbacks) {
          SafeLogger.w(
              _tag,
              'the pending retry callback cannot be parked (queue full) — '
              'answering it false right away');
          try {
            stranded(false, _currentDeviceGAID);
          } catch (e, st) {
            SafeLogger.e(_tag, 'host onComplete(false) threw: $e\n$st');
          }
        } else {
          SafeLogger.d(
              _tag,
              'a host-initiated initialize() cancelled a pending retry — the '
              'retry\'s caller is parked on this attempt instead');
          _queuedInitCallbacks.add(stranded);
        }
      }
    }
    // Round-25 — set once `onComplete(true)` + `BoolEvent(true)` have gone
    // out, so the `catch` below cannot follow a reported success with a
    // contradicting failure report. Everything that runs after that point
    // (the footgun diagnostics, the preload kick-off) is post-success work: if
    // it throws, init still succeeded and the host has already been told so.
    var successReported = false;
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
        _detachConsentListener();
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
        _ownsCrashGuard = true;
      }

      final prefs = await AdPreferences.getInstance();
      _eventLog ??= AdEventLog(prefs);
      AdaptiveFrequencySignals.setSink(
          _eventLog!.recordAdaptiveSignal); // T26: adaptive-frequency signals
      bypassAuditTrail.attach(prefs);

      // Phase 3: pipe safety params from config.
      // T88 — a remote provider gets a bounded window to answer; a slow or
      // failing backend must never block SDK init. Validated + merged onto
      // config.safety — the local values are always the fallback.
      _remoteSafetyProvider = remoteSafetyProvider;
      // T121 — fully local alternative to remoteSafetyProvider: pick the
      // ramp stage for "how long since this device's first install" BEFORE
      // any remote override below, so a remoteSafetyProvider (if also
      // supplied) always wins on a field both touch, not the ramp.
      var effectiveSafety = _rampAdjustedSafety(config, prefs);

      if (remoteSafetyProvider != null) {
        try {
          final overrides = await remoteSafetyProvider
              .fetchSafetyParamOverrides()
              .timeout(const Duration(seconds: 5));
          if (overrides != null) {
            final merged = _applyRemoteOverridesWithRevisionGuard(
                effectiveSafety, overrides, prefs,
                applyToLiveConfig: false);
            // T137 — a stale-revision rejection here just means "boot with
            // the local config's own safety params", same as if
            // remoteSafetyProvider had never returned anything at all —
            // there is no earlier "live" AdSafetyConfig yet to preserve
            // (this runs before the FIRST AdSafetyConfig.init() of this
            // session).
            if (merged != null) {
              effectiveSafety = merged;
              SafeLogger.d(_tag, '🌐 remote AdSafetyParams overrides applied');
            }
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
      // Round-25 QC round 6 (`codex` MAJOR, `agy` MAJOR) — `vip.load()` reads
      // storage, so `destroy()` can land right here. Installing this manager
      // afterwards left the torn-down SDK holding a live `VipManager` with
      // `vipReady == true` and a listener attached, i.e. VIP state resurrected
      // after teardown.
      if (_initSuperseded(initGen)) {
        vip.dispose();
        _reportAbandonedInit(onComplete, 'destroy() during the VIP load');
        return;
      }
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
          final guard =
              debugFirstInstallGuardFactory?.call() ?? FirstInstallGuard();
          // m13 — bounded: this reads the iOS Keychain through
          // flutter_secure_storage, and a Keychain read can genuinely block
          // (notably before first unlock after a reboot). `true` on timeout is
          // the conservative answer: skip the grant rather than hand out a
          // second trial window to what may be a reinstall.
          var guardTimedOut = false;
          final alreadyGranted = await guard
              .hasAlreadyGranted()
              .timeout(const Duration(seconds: 5), onTimeout: () {
            guardTimedOut = true;
            SafeLogger.w(
                _tag,
                'first-install guard read timed out — skipping the grace '
                'grant rather than risking a duplicate');
            return true;
          });
          if (alreadyGranted) {
            // Round-23 QC (reviewer C, MINOR) — a timeout means "could not
            // read", not "already granted". Burning the per-install flag on it
            // turned a slow Keychain — routine before the first unlock after a
            // reboot, which is exactly when a fresh install is first opened —
            // into a permanently lost trial day for a genuine new user, with no
            // backend to hand it back. Skipping this launch is still the right
            // conservative call; the flag stays unset so the next launch, when
            // the Keychain answers, decides properly.
            if (!guardTimedOut) {
              await prefs.markFirstInstallGraceApplied();
            }
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
            // Round-37 QC (reviewer B, MAJOR) — the Keychain read above is a
            // real, multi-second production await (m13's 5 s timeout bound),
            // and nothing between `initialize()`'s VIP-load supersede check
            // and its consent-bootstrap one guards this window. A `destroy()`
            // landing while that read was in flight disposes `vip` (round 18's
            // `_save()` guard then drops the grant just written above) — and
            // without this check the two one-shot flags below still got
            // burned, permanently destroying the free trial for a genuine
            // first-time user with no backend to hand it back. Same rule as
            // round 18: the flag is set only once the grant actually landed.
            if (vip.isDisposed) {
              SafeLogger.w(
                  _tag,
                  'first-install VIP grace abandoned (destroy() mid-grant) — '
                  'not marking either flag over a grant that was dropped');
            } else {
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
      }

      // T136 (round 2 review, MAJOR) — the GAID whitelist import and
      // first-install grace above both `await`, so a destroy() racing
      // this exact init attempt could land here with `vip.isActive` still
      // reading `false` for a session that is actually being abandoned,
      // not a real non-VIP session — wrongly persisting the exploration
      // and consuming a real day's rate-limit slot for an attempt that
      // will never produce any WaterfallTuner data at all. Same guard,
      // same convention as every other supersede check in this function.
      if (_initSuperseded(initGen)) {
        _reportAbandonedInit(
            onComplete, 'destroy() during whitelist import / VIP grace');
        return;
      }

      // VIP status for this session is now TRULY final: vip.load(), the
      // GAID whitelist import, and first-install grace above have all run
      // (and the supersede check just above confirms this attempt is
      // still the live one). Reconcile whatever pickSessionProvider
      // decided before this initialize() call started (captured into
      // `pendingExplorationAtMs` at the very top of this function, before
      // either of those two VIP mutations could have happened).
      await _reconcileProviderExplorationSlot(
          pendingExplorationAtMs: pendingExplorationAtMs,
          vipActive: vip.isActive);

      // T40 — bootstrap ConsentManager (loads persisted user choice from
      // prefs) BEFORE picking/initialising the adapter, so a previously
      // recorded isAgeRestrictedUser=true can gate AppLovin's init (it has
      // no runtime child-directed API — see AppLovinAdapter.initialize).
      final consentMgr = await ConsentManager.bootstrap(
        prefs: prefs,
        strings: config.consentDialogStrings,
      );
      // Same round-6 MAJOR, next await: `ConsentManager.bootstrap` reads
      // persisted consent, and publishing it into a torn-down SDK leaves
      // `AdManager().consent` answering for a session that no longer exists.
      // Not independently pinnable: `AdPreferences.getInstance()` is an
      // internal singleton, so a test has no seam to make `destroy()` land
      // inside `bootstrap`'s own await. Deleting this block keeps the suite
      // green. It is the symmetric one-line twin of the VIP-load abort above,
      // which *is* pinned ('a superseded attempt cannot resurrect VIP state
      // after destroy()'), and it guards the same failure: a torn-down SDK
      // whose `AdManager().consent` answers for a dead session.
      if (_initSuperseded(initGen)) {
        _reportAbandonedInit(
            onComplete, 'destroy() during the consent bootstrap');
        return;
      }
      _consentManager = consentMgr;
      _consent = consentMgr.adConsent;
      // T167 — unconditionally, on EVERY successful init, not only when
      // the auto-show consent dialog actually fires (it skips entirely
      // once a PRIOR session already recorded an answer — hasBeenAsked —
      // so a returning user's session could otherwise never populate
      // this at all before a later settings-page re-show).
      consentMgr.noteProvider(config.provider);

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
        // Round-25 QC round 7 (`codex`, BLOCKER) — this flow is deliberately
        // NOT awaited, so its outcome can land long after a `destroy()`. The
        // error handler below reopens the gate directly, and
        // `_applyUmpConsentResult` writes it too, neither of which may write
        // into whatever session is live by then. Same session epoch the
        // privacy-options form is bound to (see `_applyPrivacyOptionsResult`).
        final umpSession = _consentSessionEpoch;
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
          if (umpSession != _consentSessionEpoch) {
            SafeLogger.w(
                _tag,
                'the auto UMP flow of a torn-down session failed ($e) — '
                'dropping it (session=$umpSession, now=$_consentSessionEpoch); '
                'the live session runs, and answers for, its own consent flow');
            return;
          }
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
      final AdProviderAdapter adapter = debugAdapterFactory != null
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
      // Round-23 QC (reviewer B, BLOCKER) — remember the child-directed flag
      // the provider is actually being built with. AppLovin MAX only reads it
      // at SDK init, and this `await` can run for up to 20 seconds; a host that
      // finishes its age gate inside that window calls `setConsent()`, which
      // updates `_consent` but cannot reach the adapter already coming up. On a
      // FIRST init `setConsent()`'s own COPPA re-init branch is unreachable too
      // (`_config` and `_lastKnownConfig` are both still null at that point),
      // so nothing at all carried the flag across. See the reconcile below.
      final initAgeRestricted = _consent.isAgeRestrictedUser;
      bool ok;
      try {
        ok = await adapter
            .initialize(
              config,
              deviceGaid: _currentDeviceGAID,
              isAgeRestrictedUser: initAgeRestricted,
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
        // Round-25 QC round 6 (all three reviewers, BLOCKER) — the abort
        // check further down only covered the *success* path, so a superseded
        // attempt whose native init failed still armed a retry timer (which
        // then called `initialize()` on the torn-down SDK five seconds later)
        // and still fired `BoolEvent(false)`. The event bus replays its most
        // recent event, so that loser's `false` overwrote the winner's `true`
        // for every late subscriber — a splash that subscribed after the fact
        // was told the SDK had failed while it was in fact up.
        if (_initSuperseded(initGen)) {
          _reportAbandonedInit(onComplete, 'destroy() or a newer initialize()');
          return;
        }
        if (!_scheduleInitRetryIfNeeded(config, onComplete, isRelease)) {
          _reportInitFailure(onComplete, initGen);
        }
        return;
      }

      _initRetryAttempts = 0;
      _initRetryTimer?.cancel();
      _initRetryTimer = null;

      // Round-25 QC round 5 (`codex`, BLOCKER) — everything above this line
      // ran across awaits (GAID fetch, VIP load, consent bootstrap, up to 20s
      // of native adapter init), and the host may well have called `destroy()`
      // in the meantime. Without this check the abandoned attempt went on to
      // install `_config`/`_adapter`, re-arm the retry timer and the
      // connectivity watch, and report `onComplete(true)` — i.e. the SDK came
      // back to life *after* teardown, and a caller already told `false` by
      // `destroy()` then saw `isInitialised == true`.
      if (_initSuperseded(initGen)) {
        try {
          await adapter.dispose();
        } catch (e) {
          SafeLogger.w(_tag, 'disposing the abandoned adapter threw: $e');
        }
        _reportAbandonedInit(onComplete, 'destroy() or a newer initialize()');
        return;
      }

      // Round-23 QC (reviewer B, BLOCKER) — the child-directed flag may have
      // changed while the up-to-20s native init above was running. AppLovin MAX
      // exposes no runtime setter for it, so the adapter that just came up is
      // permanently carrying `initAgeRestricted`, and installing it would serve
      // MAX ads to a user the host has since declared child-directed.
      //
      // `setConsent()` has a COPPA re-init branch for exactly this, but on a
      // FIRST init it cannot fire: it needs `_config ?? _lastKnownConfig`, and
      // both are still null until the two lines below. So the reconcile has to
      // happen here, on the way out of init.
      //
      // Abort rather than re-init in place: `_isInitializing` is still true
      // (cleared by this method's `finally`), so a nested `initialize()` would
      // early-return, and a deferred one could not report through the host's
      // `onComplete`. Failing closed is also the correct direction for COPPA —
      // AppLovin's own adapter aborts init outright for a child-directed
      // audience, so this makes a mid-init flip behave exactly like a flag that
      // had been true from the start. `_lastKnownConfig` is set first, which is
      // what lets the existing MJ7/M2 recovery in `setConsent()` rebuild the
      // adapter if the host later corrects the flag back to false.
      // `config.isAdMob`, NOT `isAdMobProvider` — the getter reads `_config`,
      // which is still null two lines above its own assignment, so on a first
      // init it answers `false` for an AdMob app and this reconcile would tear
      // down a perfectly good AdMob adapter. (AdMob carries child-directed on
      // every ad request, so there is nothing stale to discard there.)
      if (!config.isAdMob &&
          _consent.isAgeRestrictedUser != initAgeRestricted) {
        _lastKnownConfig = config;
        if (_consent.isAgeRestrictedUser) {
          // Nothing may request an ad from here on.
          _updateCanRequestAds(false);
        }
        SafeLogger.w(
            _tag,
            '🚫 COPPA child-directed flipped to ${_consent.isAgeRestrictedUser} '
            'DURING AppLovin init — MAX only reads it at SDK init, so the '
            'adapter that just came up carries the stale value. Discarding it.');
        try {
          await adapter.dispose();
        } catch (e) {
          SafeLogger.w(_tag, 'disposing the stale-COPPA adapter threw: $e');
        }
        // Round-25 QC (reviewer B, MINOR) — this abort MUST fire the event.
        // `_reportAbandonedInit` deliberately stays silent for a *superseded*
        // attempt, because a winner is behind it and will fire its own. Here
        // there is no winner and no `destroy()`: nothing else will ever fire,
        // so a splash driven off `SimpleEventBus` (the SDK's own
        // `AdReadinessSplashController`, and the copy-paste splash in the
        // README) sits frozen until its 8 s hard cap.
        // Round-30 QC (reviewer B, BLOCKER) — and it must try again. Run the
        // trigger in the OTHER direction: a kids-category app with a
        // parent-unlockable adult tier starts init as child-directed, the
        // parent finishes the age gate inside the ≤20 s native window, and the
        // host sets `isAgeRestrictedUser: false`. The reconcile discards the
        // adapter — correctly, it carries the stale flag — and then, before
        // this, simply stopped. No adapter, no retry, and the only rebuild
        // route left (`setConsent`'s COPPA branch) needs the flag to flip
        // AGAIN, which it will not: the gate is finished. An ordinary adult
        // user got zero ads of any format for the whole session.
        //
        // That direction is strictly worse than doing nothing — keeping the
        // over-restrictive adapter would at least have served child-safe
        // inventory — and unlike the `true` direction there is no compliance
        // reason to stay dark. The retry re-enters `initialize()` with
        // `_consent` settled, so the second attempt builds with the right flag.
        //
        // The splash-unfreeze and parked-caller problems round 25/26 fixed are
        // about the EVENT BUS and the QUEUE — a late subscriber and a second,
        // different caller — not about this call's own `onComplete`. Firing the
        // bus and draining the queue immediately still answers "nobody else is
        // coming" for THOSE two audiences: neither the queued callers nor the
        // bus's late subscribers hear about a retry that only re-answers this
        // one closure.
        SimpleEventBus().fire(const BoolEvent(false));
        _drainQueuedInitCallbacks(false);
        //
        // Round-33 QC (reviewer B, MAJOR) — `onComplete` itself must be
        // answered exactly once, same as every sibling failure path in this
        // method. The previous version called it here immediately AND handed
        // the same closure to a retry, so a host that stops a splash spinner or
        // fires one "sdk_ready" event off `onComplete` did both twice.
        //
        // The two directions are NOT symmetric, so they no longer share a
        // retry decision. `isAgeRestrictedUser == true` here means the flag
        // flipped TO restricted: correctly dark, and AppLovin's own adapter
        // will refuse every future attempt while it stays that way, so a retry
        // would only burn a full backoff schedule retrying something that
        // cannot succeed — report once, immediately, as before. `false` means
        // the flag flipped AWAY from restricted: the one direction retrying
        // is for, since a fresh attempt with the corrected flag should work.
        // There `onComplete` is answered exactly once, by the retry.
        if (_consent.isAgeRestrictedUser) {
          _reportAbandonedInit(
              onComplete, 'the child-directed flag changed during init');
        } else if (!_scheduleInitRetryIfNeeded(config, onComplete, isRelease)) {
          _reportAbandonedInit(
              onComplete, 'the child-directed flag changed during init');
        }
        return;
      }

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

      // Round-17 QC, BLOCKER — reconcile against the device before the first ad
      // request of this session. A `destroy()` that interrupts a consent write
      // disowns that apply, and `_resetGuardState()` then reopens the ad gate
      // unconditionally (T63: a stale close would lock the next session out of
      // ads for good) — so a withdrawal that never finished writing could come
      // back here as personalised requests under the previous session's
      // configuration. The device's own TCF keys are what a CMP writes the
      // moment the user submits, so they are the record to trust. Cheap: a
      // local `SharedPreferences` read, and only a disagreement costs
      // anything. A disagreement fails CLOSED until the re-apply lands, and
      // arms the same debt [_recoverConsentGate] pays if it cannot finish.
      // Round-18 QC — tighten-only, like every other device-vs-applied
      // comparison: a device that looks more permissive is no reason to shut
      // anything, and shutting it here handed the reopen to a recovery that
      // would then have re-applied the permissive keys over the host's own
      // stricter decision.
      final deviceTcfAllows = await IabStorage.tcfAllowsPersonalisedAds();
      if (deviceTcfAllows == false && _committedConsent.hasUserConsent) {
        SafeLogger.w(
            _tag,
            '🔐 init: device TCF personalisation=$deviceTcfAllows disagrees '
            'with the applied consent '
            '(${consentMgr.adConsent.hasUserConsent}) — gating ads until it '
            'is re-applied');
        _updateCanRequestAds(false);
        _pessimisticGateClose = true;
        _consentGateRecoveryAttempts = 0;
        // Round-18 QC, MAJOR — through the recovery, not straight into the
        // re-apply: this closed the gate, so if the reconcile throws or hangs
        // something has to come back for it. [_recoverConsentGate] is the one
        // path that both re-applies a stricter device state and arms the
        // bounded retry when it cannot (and it times out its own UMP read).
        unawaited(
            _recoverConsentGate(knownTcfRefusal: true).catchError((Object e) {
          SafeLogger.w(_tag, 'init consent reconcile threw: $e');
        }));
      }

      // Round-25 QC round 21 — same reconcile, the US axis. Before the first ad
      // request of this session: a returning user's opt-out is already on disk
      // and the providers must carry it into the preloads further down.
      await _reconcileDeviceUsPrivacy();

      // Flipped before the callback runs, not after: from here on init HAS
      // succeeded, so nothing below may report a failure for it.
      successReported = true;
      // A host callback that throws is the host's bug, but it used to be this
      // SDK's outage: the throw skipped the `BoolEvent(true)` below (so a
      // splash waiting on the event bus never heard init finish) and landed in
      // the `catch`, which armed the retry loop described there. Contained.
      // Same BLOCKER, second window: applying consent to the providers and
      // reading the TCF string are both awaited, so `destroy()` can land
      // between the state install above and the success report below. The
      // adapter it disposed is gone; claiming success here would tell the host
      // the SDK is up while `isInitialised` is already false.
      if (_initSuperseded(initGen)) {
        _reportAbandonedInit(
            onComplete, 'destroy() or a newer initialize() during consent');
        return;
      }
      // T137 — deliberately started here, at the same "init HAS succeeded"
      // point as the success report a few lines below, not any earlier.
      // Round-2 independent review (IMPORTANT) — starting it up near the
      // top of this function (right after `_remoteSafetyProvider` is set)
      // meant a terminal adapter failure, a thrown init, or this exact
      // `_initSuperseded` abort left it ticking indefinitely: none of
      // those paths call `_resetGuardState()` or cancel it directly, and
      // while `_config` stays null each tick is a near no-op, "leaks a
      // live Timer against a session that never actually started"
      // forever is still a real bug, not just wasted CPU. `_resetGuardState()`
      // above (before this whole init attempt began) already cancelled any
      // timer a PRIOR session left running.
      _remoteSafetyRefreshTimer?.cancel();
      if (remoteSafetyProvider != null &&
          remoteSafetyAutoRefreshInterval != null) {
        _remoteSafetyRefreshTimer = Timer.periodic(
            remoteSafetyAutoRefreshInterval,
            (_) => unawaited(refreshRemoteSafetyParams()));
      }
      try {
        onComplete(true, _currentDeviceGAID);
      } catch (e, st) {
        SafeLogger.e(_tag, 'host onComplete(true) threw: $e\n$st');
      }
      SimpleEventBus().fire(const BoolEvent(true));
      _drainQueuedInitCallbacks(true);
      // Round-25 (iOS device run) — success is reported BEFORE the two footgun
      // asserts below, and that ordering is the fix, not a style choice. Both
      // asserts throw in debug/profile builds, the `catch` at the bottom of
      // this method swallows that throw, and everything after the throw was
      // therefore skipped: `onComplete` never ran and no `BoolEvent` was ever
      // fired, so a host splash sat waiting for an init-completion event that
      // could not arrive (the documented integration contract, README step 3)
      // and fell through to its hard-cap timer instead. Native init had in
      // fact succeeded. The assert is meant to shout at the developer, not to
      // fake an init failure.
      //
      // Ad loading still cannot start before the consent guard below has had
      // its say: the preload calls are further down, after both blocks.

      // Consent-coverage footgun (runtime, not config-static so it doesn't
      // false-alarm hosts that gather consent in their splash) — see
      // [consentFootgunWarning].
      final consentWarning = consentFootgunWarning(config,
          // m6 — an auto flow that has started but not yet completed still
          // counts as consent coverage.
          umpRequested: _umpRequested || _umpFlowStarted,
          consentExplicitlySet: _consentExplicitlySet);
      if (consentWarning != null) {
        // `critical`, not `w`: this is a developer config error with a legal
        // consequence, and it must reach a host that silenced ordinary logging
        // (`AdLogLevel.none`) too. It replaces the `assert` this method used to
        // end with — see the note where that assert used to live.
        SafeLogger.critical(_tag, consentWarning);
        // N2 — `assert()` below is stripped in release, so without this the
        // gap was silent in production (log-only, ads still served with NO
        // consent form ever shown to EEA/UK users). Hard-block ad requests
        // in release until the host resolves consent — via
        // requestUmpConsent(), a direct setConsent() call from their own
        // consent UI (both clear [_footgunBlocked], see [setConsent]), or by
        // fixing the config footgun itself.
        _applyConsentFootgunGuard(isRelease);
        // Ad requests are gated by the preload block below, which skips
        // itself on this warning in every build — debug and release agree, and
        // neither of them depends on an `assert` to stay compliant.
      }

      // Round-31 audit fix (MAJOR) — see [coppaUmpMismatchWarning]. Log-only
      // (not release-blocked like the consent-coverage footgun above): this
      // is a config mismatch to flag loudly, not a "no consent flow ran at
      // all" gap ads must be hard-blocked for.
      final coppaWarning = coppaUmpMismatchWarning(config,
          isAgeRestrictedUser: initAgeRestricted,
          umpWillRun: _umpRequested || _umpFlowStarted);
      if (coppaWarning != null) {
        SafeLogger.critical(_tag, coppaWarning);
      }

      // 2026-08-19 audit (Finding 7) — see [attOrderFootgunWarning]. Not
      // release-blocked like the consent footgun above: this is a
      // revenue/attribution risk, not a legal-compliance one.
      // Round-25 QC round 4 (`codex` MAJOR, `agy` MAJOR) — `defaultTargetPlatform`
      // rather than `dart:io`'s `Platform.isIOS`, which no test can influence.
      // Both reviewers deleted the `SafeLogger.critical` below and found all 16
      // tests still green: on a macOS host `Platform.isIOS` is false, so the
      // warning was always null under `flutter test` and the call site was
      // unreachable by any assertion. Flutter's own platform value is
      // overridable (`debugDefaultTargetPlatformOverride`), so the diagnostic
      // is now pinned. Same answer in production — on iOS both are true, and
      // this reads a compile-time-ish constant instead of touching `dart:io`.
      final attWarning = attOrderFootgunWarning(
          attRequested: _attRequested,
          isIos: defaultTargetPlatform == TargetPlatform.iOS);
      if (attWarning != null) {
        SafeLogger.critical(_tag, attWarning);
      }

      // Round-25 QC round 2 — a footgun config does NOT preload, in ANY build.
      // The first version of this fix moved the (since removed) asserts below
      // the preloads and argued that a debug-only ad request was acceptable;
      // a reviewer was
      // right that it is not the SDK's call to make. Before the fix, the assert
      // threw above this point and no request went out in debug either, so
      // skipping here is the behaviour hosts already had — minus the collateral
      // damage of also losing the retry timer and connectivity watch, which
      // still start below. In release `_applyConsentFootgunGuard` above already
      // blocks the requests; this makes the two builds agree instead of relying
      // on an assert to be the gate.
      if (consentWarning != null) {
        SafeLogger.w(
            _tag,
            '⏭️ App Open + banner/mrec preload skipped — no consent coverage '
            '(see the warning above); ads stay unrequested until the host '
            'resolves consent');
      } else {
        _triggerInitialPreloads(adapter);
      }

      _scheduleFirstSecondaryLoad();
      _startAdRetryTimer();
      unawaited(_startConnectivityWatch());

      // Round-25 QC round 3 (`codex`) — there are deliberately NO
      // `assert(consentWarning == null, ...)` calls here any more.
      //
      // The history is worth keeping, because the assert looked useful three
      // times and was not. `assert(false, …)` throws in debug/profile, and this
      // method's own `catch` swallows it, so it never crashed anything: all it
      // ever produced was a misleading `initialize THREW` log with a stack
      // trace pointing at the SDK. While it sat ABOVE the preload block it also
      // cost a developer who tripped it the whole session's ad services
      // (preloads, the retry timer, the connectivity watch) — the round-25 bug.
      // Moving it below fixed that but made it a gate on nothing.
      //
      // Moving it OUTSIDE the try — so it really throws out of `initialize()` —
      // is worse still: the host has already been told init succeeded, and the
      // documented splash contract does `await initialize()`, so the throw
      // lands in the splash and strands it exactly the way round-25 did.
      //
      // So the diagnostic is a `SafeLogger.critical` at each warning site
      // instead (see above): unmissable in a debug run, delivered to the host's
      // own `onLog` sink, and impossible to confuse with a real init failure.
    } catch (e, st) {
      SafeLogger.e(_tag, 'initialize THREW: $e\n$st');
      // Round-25 QC round 6 (all three reviewers, BLOCKER) — same gap as the
      // `!ok` branch above, and worse: the "adapter came up, tear it down"
      // branch below decides what to dispose by reading `_adapter`/`_config`,
      // the shared singleton fields. A stale attempt that threw *after* a
      // different attempt had already won therefore disposed the WINNER's live
      // adapter and reported `false` for a session that never failed — the
      // loser actively killing the winner. Nothing here belongs to this
      // attempt any more: `destroy()` and the re-init path have both already
      // torn down whatever it had installed.
      if (_initSuperseded(initGen)) {
        SafeLogger.w(
            _tag,
            'the attempt that threw had already been superseded by destroy() '
            'or a newer initialize() — not touching the live session');
        if (!successReported) {
          _reportAbandonedInit(onComplete, 'destroy() or a newer initialize()');
        }
        return;
      }
      // Round-25 (iOS device run), MAJOR — a retry here is only meaningful
      // while the adapter is NOT up. Past that point `_initRetryAttempts` has
      // already been reset to 0 (see the reset right after the adapter's own
      // init succeeds), so the "bounded" budget can never be spent: every
      // attempt re-initialises the adapter fine, throws again in the same
      // later step, resets the budget again and schedules retry #1 forever —
      // a permanent 5-second re-init loop that disposes and rebuilds the
      // native adapter and re-requests ads each time. Anything that throws
      // after the adapter is up (a host `onComplete` callback that throws, a
      // broken slot getter, a plugin that throws) is not fixable by running native
      // init again, so report it once and stop.
      if (successReported) {
        SafeLogger.w(
            _tag,
            'init already reported success before this throw — logging only, '
            'no failure report and no retry');
      } else if (_adapter != null && _config != null) {
        SafeLogger.w(
            _tag,
            'init failed AFTER the adapter came up — not retryable, '
            'reporting once instead of looping');
        // Round-25 QC (all three independent reviewers, MAJOR) — tear the
        // adapter down BEFORE reporting the failure. Reporting `false` while
        // `_adapter`/`_config` are still set leaves the SDK saying two
        // contradictory things at once: the host was told init failed, but
        // `isInitialised` (== `_config != null && _adapter != null`) still
        // answers true, and a live native adapter plus its fullscreen-dismiss
        // watchers and the `_syncConsentToAdapter` listener stay wired up for
        // the rest of the process. A host that does not re-`initialize()` on
        // failure then leaks that adapter — and it keeps serving.
        //
        // That is the very failure class this whole fix is about (an external
        // signal disagreeing with internal state), so it cannot be
        // reintroduced one branch over. `_disposeAdapter()` also detaches the
        // watchers and nulls both fields, which is what makes the reported
        // `false` true.
        _detachConsentListener();
        await _disposeAdapter();
        // The fields are cleared by `_disposeAdapter()` even when the
        // teardown itself throws (see its own guard), which is what makes the
        // `false` reported below true rather than just claimed.
        _reportInitFailure(onComplete, initGen);
      } else if (!_scheduleInitRetryIfNeeded(config, onComplete, isRelease)) {
        _reportInitFailure(onComplete, initGen);
      }
    } finally {
      // Only if no nested `initialize()` took over in the meantime — see
      // [_reportInitFailure]. Clearing it unconditionally would hand the flag
      // of a still-running nested init back to `false` and let a third
      // concurrent call slip past the duplicate guard.
      if (_initGen == initGen) _isInitializing = false;
    }
  }

  /// The first round of ad requests after a successful [initialize].
  ///
  /// Extracted in round-25 QC round 2 only so the footgun path can skip it in
  /// one line — see the call site for why a config with no consent coverage
  /// must not reach this in any build.
  void _triggerInitialPreloads(AdProviderAdapter adapter) {
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
  }

  /// Reports a terminal init failure to the host exactly once, containing a
  /// host callback that throws.
  ///
  /// Round-25 QC round 2 — the success report has been contained since the
  /// first half of this fix, the failure report had not: a host `onComplete`
  /// that threw here escaped `initialize()` (so `await initialize()` blew up in
  /// the host's own splash) AND skipped the `BoolEvent(false)`, leaving a
  /// splash that listens on the event bus rather than the callback waiting for
  /// a signal that was never going to come — the same outage the success path
  /// was fixed for, on the failure path.
  /// `onComplete` callbacks belonging to calls that arrived while another
  /// `initialize()` was still running.
  ///
  /// Round-25 QC round 4 (`codex`, MAJOR) — the duplicate guard used to just
  /// log "skipping duplicate" and return, so that caller was told *nothing*,
  /// ever: no `onComplete`, no event. A splash doing `await initialize()` as
  /// the second caller waited on a callback that could not arrive, which is
  /// the same hang round 25 started from, one caller over. They now wait for
  /// the in-flight attempt and get its real result — including a result that
  /// only arrives after the internal retry budget resolves.
  final List<void Function(bool, String)> _queuedInitCallbacks = [];

  /// Cap on [_queuedInitCallbacks] (`codex` round-5 minor — the list had no
  /// bound, and a host looping `initialize()` while one attempt sat through
  /// the full retry budget kept every closure alive). A host with more than
  /// this many inits in flight has a bug of its own; the overflow caller is
  /// told `false` immediately rather than parked.
  static const int _maxQueuedInitCallbacks = 32;

  /// The result being handed out, non-null **only** while
  /// [_drainQueuedInitCallbacks] is running. The duplicate-init guard answers
  /// a caller that arrives during a drain from this instead of parking it —
  /// see the comment there and in the drain.
  bool? _drainingInitResult;

  /// Hands [success] to every caller parked by the duplicate guard. Drains the
  /// list first: a queued callback is host code and may well call
  /// `initialize()` again, and a re-entrant call must not see its own entry.
  void _drainQueuedInitCallbacks(bool success) {
    if (_queuedInitCallbacks.isEmpty) return;
    // Round-25 QC round 6 (`codex` MAJOR, `agy` mutation) — round 5 drained in
    // a loop capped at 8 passes, which still dropped whoever was parked past
    // the cap. The cap is gone: while a drain is running the result is already
    // known, so a queued callback that calls `initialize()` again (the obvious
    // host reaction, and the reason the re-entrancy exists at all) is answered
    // on the spot by the duplicate guard instead of being parked into a queue
    // that may never be drained again. Nothing can grow the queue from inside
    // the drain any more; the loop below is the belt for anything else.
    // Round-25 QC round 7 (`agy`, MAJOR — but see below): saved and restored
    // rather than nulled. A queued callback is free to call `destroy()`, which
    // drains the queue itself, and a nested drain's `finally` clearing the
    // field outright would leave the rest of the outer drain running as if no
    // drain were in progress.
    //
    // The reported scenario is in fact NOT reachable: nothing can park while a
    // drain is running (the duplicate guard answers such a caller on the spot),
    // and the loop below copies-and-clears, so a nested drain hits its own
    // `isEmpty` early return before it reaches this field. Kept anyway — two
    // lines, and it is what makes the invariant hold by construction rather
    // than by that argument staying true.
    final outer = _drainingInitResult;
    _drainingInitResult = success;
    try {
      while (_queuedInitCallbacks.isNotEmpty) {
        final queued = List.of(_queuedInitCallbacks);
        _queuedInitCallbacks.clear();
        for (final cb in queued) {
          try {
            cb(success, _currentDeviceGAID);
          } catch (e, st) {
            SafeLogger.e(
                _tag, 'a queued host onComplete($success) threw: $e\n$st');
          }
        }
      }
    } finally {
      // `outer` is null for the outermost drain, which is exactly right: the
      // field must be null again once no drain is running.
      _drainingInitResult = outer;
    }
  }

  /// Whether the attempt that started as [initGen] has been superseded by a
  /// `destroy()` or by a nested `initialize()`. Both bump [_initGen].
  bool _initSuperseded(int initGen) => _initGen != initGen;

  /// Terminal report for an attempt that [_initSuperseded] says nobody is
  /// waiting for any more.
  ///
  /// Reports `false` — the SDK really is not initialised when this runs — but
  /// deliberately fires **no** `BoolEvent`. [SimpleEventBus] replays the most
  /// recent event to late subscribers, so a `false` from an attempt that lost
  /// the race could land *after* the winning attempt's `true` and leave a
  /// splash that subscribed late believing init had failed. The winner fires
  /// its own event; the host that called `destroy()` is not waiting for one.
  ///
  /// [fireEvent] is the exception: an abort with **no** winner behind it and no
  /// `destroy()` in flight — today, the COPPA mid-init flip. There the silence
  /// is the bug, not the safety, because nothing else is ever going to fire.
  ///
  /// Round-26 QC (reviewer B, MAJOR) — and the same sentence is true of the
  /// parked callers. Every other abort path has a winner or a `destroy()`
  /// behind it that drains `_queuedInitCallbacks`; this one has neither, so a
  /// host that `await`ed a second `initialize()` while the first was in flight
  /// waited forever. Whatever fires the event must also drain the queue: they
  /// are the same claim ("nobody else is coming") made to two audiences.
  void _reportAbandonedInit(void Function(bool, String) onComplete, String why,
      {bool fireEvent = false}) {
    SafeLogger.w(_tag, 'init attempt abandoned ($why) — reporting failure');
    try {
      onComplete(false, _currentDeviceGAID);
    } catch (e, st) {
      SafeLogger.e(_tag, 'host onComplete(false) threw: $e\n$st');
    }
    if (fireEvent) {
      SimpleEventBus().fire(const BoolEvent(false));
      _drainQueuedInitCallbacks(false);
    }
    // No queue handling here on purpose. A caller can only be parked while a
    // live attempt owns `_isInitializing`, and that attempt drains the queue
    // when it finishes; `destroy()` drains it and releases the flag as its
    // first two acts, and an `initialize()` arriving during the teardown waits
    // it out rather than parking (round 7). Round 6 did drain here, for a
    // caller that parked between `destroy()`'s drain and its release of the
    // flag — a window that no longer exists.
  }

  void _reportInitFailure(void Function(bool, String) onComplete, int initGen) {
    // Round-25 QC round 2 (both independent reviewers) — released BEFORE the
    // host is told, because the obvious thing for a host to do in
    // `onComplete(false)` is call `initialize()` again with a fallback config.
    // With the flag still held that call hit the duplicate guard
    // ("initialize already in progress — skipping duplicate") and was dropped
    // silently: the host had been told init failed and its own retry then did
    // nothing at all. `_initGen` is what keeps the outer `finally` from
    // clobbering the nested call's flag.
    //
    // Round-25 QC round 6 (`claude`, part of the BLOCKER) — and it must not
    // clobber it here either. This release used to be unconditional, so a
    // stale attempt reporting its own failure handed a still-running newer
    // init's busy flag back to `false` and let a third concurrent call slip
    // past the duplicate guard and build a second adapter.
    //
    // Belt-and-braces as of round 6: all three call sites now sit *after* an
    // `_initSuperseded` early return, so `_initGen == initGen` is always true
    // when we get here and no test can pin this line (deleting the condition
    // keeps the whole suite green — checked). It stays because it is one word
    // and it is the guard that stops the bug coming back if a future call site
    // reports a failure without checking for supersession first.
    if (_initGen == initGen) _isInitializing = false;
    try {
      onComplete(false, _currentDeviceGAID);
    } catch (e, st) {
      SafeLogger.e(_tag, 'host onComplete(false) threw: $e\n$st');
    }
    SimpleEventBus().fire(const BoolEvent(false));
    _drainQueuedInitCallbacks(false);
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
    // Clamped: the real schedule has exactly `_maxInitRetryAttempts` entries,
    // but a test override is allowed to be shorter (usually one entry).
    // Round-25 QC round 12 (`codex`, MINOR) — an EMPTY override is treated as
    // no override, not as an index error. `@visibleForTesting` is an analyzer
    // annotation only, so this seam is reachable in release; with `[]` the
    // clamp below threw `Invalid argument(s): 0`, the outer catch re-entered
    // this same function, the second throw escaped `initialize()` and the
    // host's `onComplete` was never called at all.
    final override = debugInitRetryDelays;
    final schedule = (override != null && override.isNotEmpty)
        ? override
        : _kInitRetryDelays;
    final raw = schedule[_initRetryAttempts.clamp(0, schedule.length - 1)];
    // Round-25 QC round 13 (`codex`, MINOR) — a debug override is capped at the
    // longest production backoff. Uncapped, `[Duration(days: 36500)]` plus a
    // failing adapter init left `onComplete` parked in `_pendingRetryOnComplete`
    // for a century: `initialize()` returns, the host is never answered, and no
    // timeout anywhere fires. A test seam should be able to make the retry
    // faster, never slower than the real thing.
    final delay = raw > _kInitRetryDelays.last ? _kInitRetryDelays.last : raw;
    debugLastInitRetryDelay = delay;
    _initRetryAttempts++;
    SafeLogger.d(
        _tag,
        () =>
            '⏲️ scheduling init retry #$_initRetryAttempts in ${delay.inSeconds}s');
    _initRetryTimer?.cancel();
    _pendingRetryOnComplete = onComplete;
    _initRetryTimer = Timer(delay, () {
      // Cleared here: from this instant the retry attempt itself owns the
      // callback and will answer it (directly, or through the queue drain), so
      // there is nothing left for a canceller to rescue.
      _pendingRetryOnComplete = null;
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
    _scheduleStateSnapshotRecompute();
    final vip = _vipManager;
    final ad = _adapter;
    if (vip == null || ad == null) return;
    if (vip.isActive) {
      SafeLogger.d(_tag, '🔒 VIP active — ad loads suppressed');
      return;
    }
    SafeLogger.d(_tag, '🔓 VIP inactive — kicking secondary preload');
    // Round-23 QC (reviewer C, MINOR) — an inline ad widget that mounted while
    // VIP was active never ran its `_initBanner`, and that retry lives in the
    // `initRevision` builder, not in the VIP one. So the surfaces stayed blank
    // on the screen the user was actually looking at when the entitlement ran
    // out — they came back only after a route change or an app restart. Bumping
    // the revision is exactly the "re-attempt init, but only where there is no
    // ad" signal those widgets already implement.
    initRevision.value++;
    unawaited(loadAppOpenAd());
    unawaited(loadInterstitial());
    unawaited(loadRewardedAd());
    // T148 — rewardedInterstitial was missing from this fast-refill path,
    // left to wait out the 5-minute periodic retry timer instead of
    // reloading immediately like its three siblings above.
    unawaited(loadRewardedInterstitialAd());
    // T65 (phase 2) — no widget key at this call site; shares the sentinel
    // key (see its doc comment).
    unawaited(ad.preloadBanner(_globalBannerWarmupKey));
    unawaited(ad.preloadMrec(_globalMrecWarmupKey));
  }

  /// Attach listeners to the four fullscreen slots so we can record the real
  /// dismiss instant (when state transitions OUT of [AdSlotState.showing]).
  /// This is the source of truth for [_lastFullscreenDismissAt] used by the
  /// app-open-on-resume guard — replacing the brittle adapter-callback writes
  /// that fired at the wrong moment for rewarded ads (rewarded `onDone` is
  /// called when the reward is earned, not when the ad is actually dismissed,
  /// causing the 2 s guard to leak through after a 30 s rewarded video).
  void _attachFullscreenDismissWatchers() {
    final ad = _adapter;
    if (ad == null) return;
    // Round-31 audit fix — rewardedInterstitialSlot was missing here, so
    // that format (AdMob-only) fell back to the exact brittle
    // adapter-callback timestamp this mechanism exists to replace: AdMob
    // fires onUserEarnedReward (which stamps _lastFullscreenDismissAt in
    // showRewardedInterstitialAd's onDone) BEFORE onAdDismissed, so the
    // suppression window could expire while the ad was still on screen.
    // AppLovin's slot never leaves idle for this type (documented no-op),
    // so including it here is always safe.
    final slots = [
      ad.appOpenSlot,
      ad.interstitialSlot,
      ad.rewardedSlot,
      ad.rewardedInterstitialSlot,
    ];
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

  @visibleForTesting
  void debugAttachFullscreenDismissWatchers() =>
      _attachFullscreenDismissWatchers();

  @visibleForTesting
  void debugDetachFullscreenDismissWatchers() =>
      _detachFullscreenDismissWatchers();

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
      SafeLogger.d(_tag, 'first secondary load → inter + rewarded + RI');
      unawaited(loadInterstitial());
      unawaited(loadRewardedAd());
      // T148 — rewardedInterstitial was missing here too, same gap as
      // _onVipActiveChanged above.
      unawaited(loadRewardedInterstitialAd());
    }
  }

  /// T121 ramp stage for "how long since this device's first install",
  /// factored out of [initialize] so [refreshRemoteSafetyParams] can rebase
  /// onto it too.
  ///
  /// Round-30 audit (MAJOR) — [refreshRemoteSafetyParams] used to merge
  /// remote overrides onto the raw `config.safety` instead of this, silently
  /// reverting every field the ramp had adjusted (but the remote payload
  /// doesn't mention) back to day-0 config on every refresh. Recomputed
  /// fresh each call (not cached from `initialize()`) since the ramp is
  /// time-based — the device may have crossed into a later stage since init.
  AdSafetyParams _rampAdjustedSafety(AdConfig config, AdPreferences prefs) {
    final rampSchedule = config.safetyRampSchedule;
    if (rampSchedule == null || rampSchedule.isEmpty) return config.safety;
    final installedAtMs =
        prefs.getFirstInstallAtMs() ?? DateTime.now().millisecondsSinceEpoch;
    final elapsed = Duration(
        milliseconds: DateTime.now().millisecondsSinceEpoch - installedAtMs);
    Duration? bestStage;
    for (final stage in rampSchedule.keys) {
      if (stage <= elapsed && (bestStage == null || stage > bestStage)) {
        bestStage = stage;
      }
    }
    if (bestStage == null) return config.safety;
    SafeLogger.d(_tag,
        '📈 safetyRampSchedule: applied stage $bestStage (device age $elapsed)');
    return rampSchedule[bestStage]!;
  }

  /// T111 — re-fetch [RemoteAdSafetyProvider] overrides and apply them
  /// immediately, without a full `destroy()`+`initialize()` cycle. Mirrors
  /// `VipManager.refreshRevocationList`'s contract: **fails open** on every
  /// error (fetch throws, times out, or returns `null`) by leaving the
  /// currently-applied [AdSafetyParams] untouched — a network hiccup must
  /// never loosen or tighten safety limits by accident.
  ///
  /// No-op if [initialize] was never called with a `remoteSafetyProvider`, or
  /// if the SDK isn't currently initialised.
  Future<void> refreshRemoteSafetyParams() async {
    final provider = _remoteSafetyProvider;
    final cfg = _config;
    if (provider == null || cfg == null) return;
    // T132 — captured alongside `cfg` so the guard right before the global
    // write below can tell "destroyed mid-fetch" apart from the more
    // dangerous "destroy()+initialize() BOTH completed mid-fetch, so
    // _config is non-null again but is now a different (newer) session's
    // config than `cfg` above". Checking `_config == null` alone only
    // caught the first case.
    final myGen = _initGen;

    Map<String, dynamic>? overrides;
    try {
      overrides = await provider
          .fetchSafetyParamOverrides()
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      SafeLogger.w(_tag,
          '⚠️ refreshRemoteSafetyParams: fetch failed, keeping current params: $e');
      return;
    }
    if (overrides == null) return;

    final prefs = await AdPreferences.getInstance();

    // T132 (round 2, independent adversarial review) — checking
    // `_initSuperseded` right after the fetch above and NOT again here used
    // to leave this exact same race open across the `await
    // AdPreferences.getInstance()` suspension point: a destroy()+
    // initialize() cycle completing between that early check and the merge
    // below would still slip through. The only check that actually matters
    // for correctness is the one immediately before the global write —
    // deliberately a single check, placed here and nowhere earlier, so a
    // future edit that adds another `await` between this line and the
    // write below can't reopen the same gap without moving this guard too.
    if (_initSuperseded(myGen)) {
      SafeLogger.w(_tag,
          'refreshRemoteSafetyParams: session superseded mid-fetch — overrides discarded');
      return;
    }

    // Round-31 audit fix — initialize() wraps this same merge in a try/catch
    // (above); this method did not, asymmetrically. A malformed remote
    // payload (e.g. a numeric field serialized as `Infinity`, which
    // `double.toInt()` throws `UnsupportedError` on — see
    // RemoteAdSafetyProvider.posInt) would then escape this async method
    // uncaught instead of falling back to "keep current params" as the
    // class doc promises.
    try {
      // T137 — `null` means the revision guard rejected this payload as
      // stale; the currently-live AdSafetyConfig (set by whatever payload
      // is actually newest) must be left exactly as it is, not overwritten
      // with a `merged` computed from this call's own now-stale baseline.
      // `applyToLiveConfig: true` folds the actual write into this same
      // synchronous call — see the method's doc comment for why that
      // matters against overlapping refreshes.
      final merged = _applyRemoteOverridesWithRevisionGuard(
          _rampAdjustedSafety(cfg, prefs), overrides, prefs,
          applyToLiveConfig: true);
      if (merged == null) return;
      SafeLogger.d(_tag, '🌐 refreshRemoteSafetyParams: applied new overrides');
    } catch (e) {
      SafeLogger.w(_tag,
          '⚠️ refreshRemoteSafetyParams: applying overrides failed, keeping current params: $e');
    }
  }

  /// T137 — shared by [initialize]'s one-time fetch and
  /// [refreshRemoteSafetyParams]'s explicit/periodic ones. If [overrides]
  /// carries an int `revision` strictly lower than the last one this SDK
  /// actually applied (persisted in [prefs]), the whole payload is rejected
  /// and [local] is returned unchanged — a stale/rolled-back remote config
  /// must not undo a newer one already live. No `revision` key (or one
  /// that isn't an int) skips this guard entirely — always-apply, matching
  /// every release before this field existed.
  ///
  /// Returns `null` when the payload is rejected as stale — the caller must
  /// then apply NOTHING at all (not even [local]), since [local] is only
  /// the freshly-recomputed ramp-adjusted baseline, not whatever is
  /// currently live in [AdSafetyConfig]. Calling
  /// `AdSafetyConfig.updateParams(local)` on a rejection would silently
  /// discard every override already applied by an earlier, newer-revision
  /// payload — the opposite of what "reject the stale one, keep the
  /// current one" is supposed to mean.
  ///
  /// T137 round 2 (independent adversarial review, BLOCKING) — this used to
  /// be `async`, `await`-ing the persisted-revision write between the check
  /// and the caller's own (also awaited-apart) `AdSafetyConfig.updateParams`
  /// call. Two overlapping refreshes (exactly what periodic auto-refresh
  /// makes routine once the interval is shorter than the provider's
  /// latency) could both pass the "is this newer" check before either
  /// one's write landed, and whichever one's async tail happened to finish
  /// LAST won — regardless of which revision was actually newer, so an
  /// older payload could roll back a newer one already live.
  ///
  /// Now deliberately fully SYNCHRONOUS — no `await` anywhere in this
  /// method — and [applyToLiveConfig] folds the actual
  /// `AdSafetyConfig.updateParams` write into this same synchronous step
  /// for the `refreshRemoteSafetyParams` path. Dart's single-threaded event
  /// loop cannot interleave another call between two statements with no
  /// suspension point between them, so the compare-and-claim on
  /// [_lastAppliedRemoteSafetyRevision] and the live-state write happen
  /// atomically relative to any other refresh in flight — whichever call's
  /// *own* fetch happens to resolve and reach this method first wins the
  /// comparison, regardless of how long some other call's fetch or
  /// persistence write takes. Persisting to [prefs] is fire-and-forget
  /// (`unawaited`) — durability across app restarts only, not part of the
  /// concurrency guard (the in-memory field is authoritative for that,
  /// seeded from the persisted value on first use so a value from a
  /// previous run isn't forgotten across a restart).
  AdSafetyParams? _applyRemoteOverridesWithRevisionGuard(
      AdSafetyParams local, Map<String, dynamic> overrides, AdPreferences prefs,
      {required bool applyToLiveConfig}) {
    final revision = overrides['revision'];
    if (revision is int) {
      final lastApplied =
          _lastAppliedRemoteSafetyRevision ?? prefs.getRemoteSafetyRevision();
      if (lastApplied != null && revision < lastApplied) {
        SafeLogger.w(_tag,
            '⚠️ remote safety override rejected: revision $revision is older than already-applied $lastApplied');
        return null;
      }
      _lastAppliedRemoteSafetyRevision = revision;
      unawaited(prefs.setRemoteSafetyRevision(revision));
    }
    final merged = applyRemoteSafetyOverrides(local, overrides);
    if (applyToLiveConfig) {
      AdSafetyConfig.updateParams(merged, isRelease: kReleaseMode);
    }
    return merged;
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
    // Round-38 audit fix (MAJOR) — every OTHER consent-apply site that
    // writes to the native provider after an `await` (see
    // `_recoverConsentGate` and its siblings) captures the epoch and loses
    // to a newer intent. This call's own tail write below did not, so two
    // overlapping setConsent() calls could land in either order: an older,
    // already-superseded call finishing last would silently re-apply its
    // stale value to the native AdMob/AppLovin SDK even though `_consent`
    // (and everything the host reads back) correctly reflected the newer
    // call. Captured once here, checked before the tail write.
    final consentEpoch = _consentIntentEpoch;
    // MJ7 — capture this BEFORE the assignment below: the AppLovin COPPA check
    // further down needs the value the provider was actually initialised with,
    // and `_consent` is overwritten on the next line.
    final previousAgeRestricted = _consent.isAgeRestrictedUser;
    // Round-26 audit (MAJOR, claude), fix attempt 3 — scope
    // [_consentProviderApplyInFlight] to only the tightening direction (GDPR
    // withdrawal, a fresh CCPA opt-out). A loosening change (granting
    // consent, e.g. this test's COPPA-on-AdMob case) has no stale-config
    // window worth guarding — `canRequestAds` reading momentarily false on
    // every single setConsent() call, tightening or not, is more collateral
    // than the actual risk calls for (attempt 3, step 1 caught this: a
    // synchronous `unawaited(setConsent(...))` + immediate `canRequestAds`
    // read, exactly the pattern the COPPA hard-stop tests use to assert
    // their OWN hard-stop happened synchronously, tripped on this flag
    // instead for an unrelated, non-tightening consent grant).
    final previousApplied = _lastAppliedConsent ?? _consent;
    final tighteningPersonalisation =
        (previousApplied.hasUserConsent && !consent.hasUserConsent) ||
            (!previousApplied.doNotSell && consent.doNotSell);
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
      try {
        await _consentManager!.set(settings, config: _config);
      } catch (e, st) {
        // Round-18 QC, BLOCKER — a persist failure must never stop the
        // decision from reaching the providers. `ConsentManager.set()` updates
        // its record FIRST, persists SECOND and applies to the providers LAST,
        // so a store that refuses the write (a full disk, an OEM store that
        // throws) used to leave the record saying "withdrawn" while AdMob and
        // AppLovin still held the personalised configuration — and the host
        // got an exception instead of enforcement. Carry on: the apply further
        // down IS the enforcement, and losing the value across a restart is
        // by far the lesser failure (the init reconcile re-derives it from the
        // device's own TCF keys anyway).
        SafeLogger.e(_tag, 'consent persist failed, applying anyway: $e\n$st');
      }
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
      // Round-39 audit fix (MAJOR) — this was the one sibling write round-38's
      // epoch guard never reached: it calls `applyConsentToProviders` directly
      // then `return`s below before the guarded tail write at the bottom of
      // this function ever runs. Two overlapping COPPA-flipping calls could
      // both reach here; without this check the older one's stale write can
      // land after the newer one's, silently re-enforcing a withdrawn (or
      // wrongly child-directed) decision on the real AppLovin SDK.
      // Round-39 audit re-review (MINOR, independent Gemini pass) — this
      // whole re-init decision must live INSIDE the same epoch check above,
      // not just the provider write: a superseded call reaching here with
      // `_isInitializing` already back to false (the newer call's own
      // re-init already completed) would otherwise still fire a whole extra,
      // redundant `initialize()` cycle from a stale, overridden intent.
      if (consentEpoch == _consentIntentEpoch) {
        await applyConsentToProviders(consent, config: cfg);
        // No infinite-recursion risk: initialize() reaches consent through
        // `_consentManager.set(...)`, not through this method, and the one
        // setConsent() call it does trigger (via auto-UMP) carries the child
        // flag through unchanged — so it cannot re-enter this branch.
        //
        // It CAN be a no-op though: initialize() early-returns while another
        // init is in flight. Say so rather than leaving it silent — a host
        // that flips this flag mid-init would otherwise be left wondering
        // why AppLovin never picked it up.
        if (_isInitializing) {
          SafeLogger.w(
              _tag,
              '⚠️ COPPA flag changed while initialize() is still running — the '
              'AppLovin re-init cannot run now. Call initialize() again once it '
              'completes, or set the flag before initialize().');
        } else {
          unawaited(initialize(config: cfg, onComplete: (_, __) {}));
        }
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
    // Round-38 audit follow-up (MAJOR-2, real fix — the epoch guard further
    // below on `_adapter?.applyConsent` only protects a MINOR secondary write
    // (AdMob's per-request npa flag); this is the one that actually matters).
    // `applyConsentToProviders` is where the real native write happens:
    // AppLovin's `setHasUserConsent`/`setDoNotSell` fire synchronously the
    // instant it's called, then it awaits AdMob's `updateRequestConfiguration`
    // platform-channel round trip. Both are effectively "last message issued
    // wins" on the native side — so the actual failure mode is an OLDER call
    // that gets delayed somewhere ABOVE this point (the `_consentManager!
    // .set()` persist-await, most likely) long enough for a NEWER overlapping
    // call to race ahead of it and issue ITS write first. When the older
    // call's delay finally clears, it would otherwise issue its own (stale)
    // write chronologically AFTER the newer one, silently overwriting the
    // correct, newer value on the real AdMob/AppLovin SDK. Checking the
    // epoch right here — immediately before the write is issued, not after —
    // is the only point that can actually prevent it: once
    // `applyConsentToProviders` is called, the native side has already been
    // told, and no later check can undo that.
    //
    // `debugSetConsentTailWriteBarrier` (test-only) is awaited HERE, before
    // either epoch check below — not after — because delaying a call after
    // it already reached `applyConsentToProviders` would be too late to
    // prove anything: the real native write already happened by then. This
    // lets a test hold an older call open at exactly the point a real delay
    // (e.g. the `_consentManager!.set()` persist-await above) would, while a
    // newer overlapping call races ahead and completes its own write first.
    final tailWriteBarrier = debugSetConsentTailWriteBarrier;
    if (tailWriteBarrier != null) await tailWriteBarrier;
    if (consentEpoch == _consentIntentEpoch) {
      if (tighteningPersonalisation) _consentProviderApplyInFlight = true;
      try {
        await applyConsentToProviders(consent, config: _config);
      } finally {
        if (tighteningPersonalisation) _consentProviderApplyInFlight = false;
      }
    } else {
      SafeLogger.d(
          _tag,
          'setConsent: superseded by a newer intent before its provider '
          'write ran — skipping (the newer call\'s own write is the one '
          'that must land)');
    }
    // Keep the adapter's per-request personalization (AdMob npa) in sync.
    // Guarded by the same epoch — an older, already-superseded call must
    // lose here too (round-38 MAJOR fix).
    if (consentEpoch == _consentIntentEpoch) {
      _adapter?.applyConsent(consent);
    }
    // N2 — the footgun block just cleared and ads may already be running;
    // refill slots that were held back while it was blocked.
    if (wasFootgunBlocked && canRequestAds && !_isVipMember) {
      SafeLogger.d(
          _tag, '🔓 consent footgun resolved → refilling held ad slots');
      _retryRefillAds();
    }
  }

  /// Round-31 audit — CCPA/CPRA (Cal. Civ. Code §1798.135) requires "Do Not
  /// Sell/Share" to be an end-user-executable choice, not just an app-level
  /// constant a developer hardcodes. `AdConsent.doNotSell`/
  /// `ConsentSettings.doNotSell` already flow correctly through
  /// [ConsentManager]/[_syncConsentToAdapter] to both providers and to
  /// persistence (see that listener's MJ5/B1 comments) — what was missing
  /// was a convenience entry point + a ready-made widget
  /// ([CcpaOptOutToggle]) a California-facing host can actually show a user,
  /// instead of building the `ConsentManager.set(current.copyWith(...))`
  /// call and its own UI from scratch.
  ///
  /// Safe to call before [initialize] — [ConsentManager] persists the
  /// choice through [AdPreferences] regardless, and it is picked up the
  /// next time consent is applied to a provider.
  Future<void> setDoNotSell(bool value) async {
    final mgr = _consentManager;
    if (mgr == null) {
      SafeLogger.w(_tag,
          'setDoNotSell($value) called before initialize() — ConsentManager not ready, ignored');
      return;
    }
    await mgr.set(mgr.current.copyWith(doNotSell: value));
  }

  /// Current CCPA "Do Not Sell" choice — `false` (default/unset) until the
  /// host reads it from [ConsentManager]/[setDoNotSell]. `false` before
  /// [initialize] too, same as [consent]'s own default.
  bool get doNotSell => _consentManager?.current.doNotSell ?? false;

  /// Listener bound to [ConsentManager.listenable]; pushes the latest consent
  /// into the provider adapter so AdMob's per-request `npa` flag tracks every
  /// consent change (dialog answer, set/reset, privacy screen).
  /// Detaches [_syncConsentToAdapter] from the consent listenable, swallowing
  /// anything the removal throws.
  ///
  /// Round-25 QC round 3 (`claude`, MAJOR) — every caller used to inline this
  /// line, and at two of the three sites it shared a `try` with the teardown
  /// that follows it: in `initialize()`'s post-success failure branch a throw
  /// here would skip `await _disposeAdapter()` entirely, so the host would be
  /// reported `false` while `_adapter`/`_config` stayed set and `isInitialised`
  /// kept answering true — the exact contradiction that branch exists to
  /// prevent. `destroy()` had the same shape one field over.
  ///
  /// Honest caveat on the guard itself: no reachable path throws here today.
  /// Flutter's `ChangeNotifier.removeListener` is explicitly safe to call
  /// after `dispose()`, and `ConsentManager`'s constructor is private so no
  /// host can substitute a `listenable` that throws — deleting the try/catch
  /// leaves every test in `init_post_success_throw_test.dart` green, and that
  /// is documented there rather than hidden. What the round-3 fix really buys
  /// is the *decoupling*: three call sites share one statement, and no future
  /// throw here can take an adapter teardown down with it.
  void _detachConsentListener() {
    try {
      _consentManager?.listenable.removeListener(_syncConsentToAdapter);
    } catch (e) {
      SafeLogger.w(_tag, 'detaching the consent listener threw: $e');
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
  /// Round-39 audit test seam: also honours [debugForceAutoUmpError], same as
  /// the init-time auto-UMP flow, so both retry call sites' `runZonedGuarded`
  /// wrapping can be exercised without a real UMP channel.
  Future<UmpConsentResult> _retryUmpConsent() {
    if (debugForceAutoUmpError != null) {
      throw debugForceAutoUmpError!;
    }
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

    // Round-25 QC round 7 (`codex`, BLOCKER) — the flow below presents a
    // native form and can therefore take minutes. A `destroy()` in the
    // meantime means this result belongs to a session that is gone, and the
    // gate it would write is the live session's. Captured here rather than
    // inside the apply so it covers the whole round trip.
    final session = _consentSessionEpoch;

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
    final cm = _consentManager;
    if (cm != null) {
      if (result.error != null) {
        // Audit fix (post-T210) — `offline` was a declared reason nothing
        // ever produced: every UMP failure was classified as `timeout` or
        // `platformError` even when the real cause was the device having no
        // connectivity at all (the actual native-plugin error message for
        // that case varies by platform/SDK version and isn't reliable to
        // string-match).
        //
        // codex round-1 fix — `isConnected` alone is not enough: this call
        // commonly runs BEFORE `_startConnectivityWatch()` has resolved (the
        // documented pattern is calling `requestUmpConsent()` from splash,
        // ahead of `initialize()`; the auto-UMP flow starts UMP before the
        // connectivity watch too), and `isConnected` optimistically returns
        // `true` while `!_connectivityReady` — that is a "we don't actually
        // know yet" state, not a real online reading. Only classify as
        // `offline` when `_connectivityReady` confirms this is a real
        // reading, not the pre-ready optimistic default; otherwise fall back
        // to the text-based classification, same as before this fix.
        final reason = _connectivityReady && !isConnected
            ? ConsentFallbackReason.offline
            : result.error!.toLowerCase().contains('timed out')
                ? ConsentFallbackReason.timeout
                : ConsentFallbackReason.platformError;
        await cm.recordFallback(
          reason: reason,
          policyRevision: kUmpPolicyRevision,
        );
      } else {
        await cm.clearFallback();
      }
    }
    await _applyUmpConsentResult(result, session: session);
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
    int? session,
  }) async {
    // Round-25 QC round 7 (`codex`, BLOCKER) — dropped rather than re-read
    // (which is what the privacy-options twin does): the live session is
    // running its own UMP flow and owns the gate until that flow answers.
    // Writing this result would open a gate the live session is deliberately
    // holding shut — and its config may differ from the dead session's (a
    // different `umpTagForUnderAgeOfConsent` is the case with teeth).
    if (session != null && session != _consentSessionEpoch) {
      SafeLogger.w(
          _tag,
          'a UMP result from a torn-down session arrived '
          '(session=$session, now=$_consentSessionEpoch) — dropping it instead '
          'of writing it over the live session\'s consent gate');
      return;
    }
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
  /// T149 audit test seam: also honours [debugForceAutoUmpError], same as
  /// [_retryUmpConsent], so both retry call sites' `runZonedGuarded`
  /// wrapping can be exercised without a real UMP channel.
  Future<void> _recheckAbandonedUmpForm() async {
    if (debugForceAutoUmpError != null) {
      throw debugForceAutoUmpError!;
    }
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
    //
    // Round-13 QC (round 11), BLOCKER — and anything QUEUED BEHIND a running
    // apply shuts the gate too, whatever it says. Whether this result is a
    // withdrawal cannot be known here: the ordinary one (personalisation off,
    // ads still allowed) reports `canRequestAds=true` and shows up only in the
    // TCF purposes, which are read inside the runner. Until the runner gets
    // there the provider still holds the OLD configuration, so an open gate
    // means a personalised request after a withdrawal. Closing it costs a
    // queued *grant* nothing but the wait — the runner reopens it once the
    // write lands.
    if (!result.canRequestAds) {
      _updateCanRequestAds(false);
    } else if (_consentApplyRunning) {
      _updateCanRequestAds(false);
      // Round-13 QC (round 12), MAJOR — this close is a guess, not a decision:
      // nothing here says the queued result is restrictive. So it is the one
      // close that is owed a reopen, and [_recoverConsentGate] is what pays it
      // if the runner cannot. Set after the call above, which clears it.
      _pessimisticGateClose = true;
      // Round-16 QC, MAJOR — the retry budget belongs to ONE debt, not to the
      // session. A debt that burned all three attempts and was then settled by
      // an ordinary apply used to leave the counter at 3, so the next guessed
      // close was refused its very first retry and stayed shut for good.
      _consentGateRecoveryAttempts = 0;
    }
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
      // Round-13 QC (round 12), MAJOR — one failing apply must not abandon the
      // intents queued behind it. It used to unwind the whole drain, leaving a
      // newer decision (typically the one that would have reopened the gate
      // round 11 shut) queued and never applied. The first error is still
      // handed to the caller, once everyone has had their turn.
      Object? firstError;
      StackTrace? firstStack;
      while (_pendingConsentApply != null) {
        final next = _pendingConsentApply!;
        _pendingConsentApply = null;
        try {
          await _applyConsentResultOnce(next);
        } catch (e, st) {
          SafeLogger.e(_tag, 'consent apply failed: $e\n$st');
          firstError ??= e;
          firstStack ??= st;
        }
      }
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStack!);
      }
    } finally {
      // Only the current owner may release the runner — see
      // [_consentApplyRunToken].
      if (_consentApplyRunToken == token) {
        _consentApplyRunning = false;
        // Round-13 QC (round 12) — see [_recoverConsentGate]. The round-11
        // pessimistic close needs someone to lift it when the apply that was
        // meant to never gets there.
        unawaited(_recoverConsentGate().catchError((Object e) {
          SafeLogger.w(_tag, '_recoverConsentGate threw: $e');
        }));
      }
    }
    return result;
  }

  /// Guards [_recoverConsentGate] against re-entering itself through the
  /// apply it starts.
  bool _consentGateRecovering = false;

  /// Whether the ad gate is shut only because a result was queued behind a
  /// running apply (round 11), rather than because anything actually said ads
  /// were not allowed. Only such a close may be lifted by
  /// [_recoverConsentGate]; a real restrictive close is nobody else's business.
  bool _pessimisticGateClose = false;

  /// What is actually applied to the providers right now. Every
  /// device-vs-applied comparison reads this, never the in-memory value alone
  /// — see [lastConsentAppliedToProviders] for why they differ.
  AdConsent get _committedConsent =>
      lastConsentAppliedToProviders ?? _consentManager?.adConsent ?? _consent;

  /// Round-13 QC (round 12), MAJOR — lift a pessimistic gate close that no
  /// apply is going to lift.
  ///
  /// Round 11 shuts the ad gate for anything queued behind a running apply,
  /// because a queued result cannot be known to be a grant. Normally the
  /// runner reopens it after the write. But an apply can end without writing
  /// anything: its values get superseded (a host `setConsent`, a `destroy()`),
  /// or the write itself throws. Nothing else in the SDK ever sets
  /// `_canRequestAds` back to true — `setConsent` deliberately does not — so
  /// the close would be permanent, and every ad surface in the app would stay
  /// dark for the rest of the session.
  ///
  /// Costs nothing on the ordinary path: the gate is already open by the time
  /// this runs, so it returns before touching UMP.
  /// [knownTcfRefusal] says the caller has ALREADY read a TCF personalisation
  /// refusal off the device (the init reconcile does exactly that before
  /// handing the re-apply over). Round-21 QC (codex), BLOCKER — without it the
  /// offline branch below re-read the same keys to establish a fact it was
  /// already given, and that read can throw or come back `null` (a storage
  /// error, `gdprApplies` cleared under us): the withdrawal was then silently
  /// dropped and both providers stayed personalised under a refusal.
  Future<void> _recoverConsentGate({bool knownTcfRefusal = false}) async {
    if (!_recoveryStillOwed) return;
    if (_consentGateRecovering) return;
    _consentGateRecovering = true;
    // Round-13 QC (round 13), BLOCKER — every await below is a window in which
    // a real consent decision can start, and this recovery must lose to it.
    // So the whole ownership is rechecked after each one, not just at entry:
    // reopening the gate while a withdrawal is mid-apply would serve a
    // personalised ad under the old configuration, which is the bug rounds
    // 9-12 exist to prevent.
    final epoch = _consentIntentEpoch;
    try {
      // Device truth, not our bookkeeping: if UMP itself says ads cannot be
      // requested then the gate is shut for a real reason and must stay shut.
      final UmpConsentResult ump;
      try {
        ump = await core_ump
            .recheckUmpConsentStatus()
            .timeout(_consentGateRecoveryTimeout);
      } catch (e) {
        // Round-13 QC (round 13), MAJOR — a transient channel failure (or a
        // native side that never answers) must not be the end of it. The debt
        // stays armed and nothing else would come back for it, so every ad
        // surface would stay dark exactly as if this recovery were not here.
        SafeLogger.w(_tag,
            '🔐 consent gate recovery could not reach UMP ($e) — retrying');
        // Round-20 QC, BLOCKER — retrying settles the GATE. It does not settle
        // a withdrawal the device is already reporting, and this is the path
        // the init reconcile hands its re-apply to, so returning here left the
        // providers personalised under a refusal until UMP came back — three
        // retries, then never. Tightening needs no UMP; see
        // [_applyDeviceWithdrawal].
        // Short-circuit on purpose: with the refusal already in hand there is
        // no second read to fail.
        final refuses = knownTcfRefusal ||
            await IabStorage.tcfAllowsPersonalisedAds() == false;
        if (refuses &&
            _committedConsent.hasUserConsent &&
            _consentRecoveryStillOwns(epoch)) {
          await _applyDeviceWithdrawal(null);
        }
        return;
      }
      // Round-14 QC, MAJOR — ownership is re-checked before ANY write this
      // run makes, the settle below included. A stale answer that clears the
      // debt flag would strand the newer apply's own guessed close: nothing
      // else ever sets `_canRequestAds` back to true, so the gate would stay
      // shut for the session. Same reason this must not clear a debt armed by
      // a session that started after a `destroy()`.
      if (!_consentRecoveryStillOwns(epoch)) return;
      if (!ump.canRequestAds) {
        // A real "no" — the debt is settled by the answer itself.
        _pessimisticGateClose = false;
        _consentGateRecoveryAttempts = 0;
        return;
      }
      final tcfAllows = await IabStorage.tcfAllowsPersonalisedAds();
      if (!_consentRecoveryStillOwns(epoch)) return;
      final applied = _committedConsent;
      // Round-18 QC, BLOCKER — tighten-only, the same rule
      // [_recheckConsentOnResume] follows. A device that looks MORE permissive
      // than what is applied is no authority to grant: a host `setConsent(
      // hasUserConsent: false)` — a parental toggle, a CCPA switch — is a newer
      // decision than whatever a CMP left in the TCF keys, and re-applying the
      // keys over it would serve personalised ads against it. That direction
      // falls through to the plain reopen below instead: non-personalised ads
      // under the stricter applied state, which is always safe.
      if (tcfAllows == false && applied.hasUserConsent) {
        // The applied configuration does not match the device — reopening here
        // would serve ads under a personalisation setting the user changed.
        // Apply the device state instead; that write reopens the gate itself.
        SafeLogger.w(
            _tag,
            '🔐 consent gate was left shut with nothing to reopen it and the '
            'applied state disagrees with the device — re-applying');
        await _applyDeviceWithdrawal(ump);
        return;
      }
      SafeLogger.w(
          _tag,
          '🔐 consent gate was left shut by an apply that never landed '
          '(superseded, or its write failed) — reopening: what is applied '
          'already matches the device');
      _updateCanRequestAds(true);
      _consentGateRecoveryAttempts = 0;
      // Round-14 QC, MINOR — the ordinary apply refills held slots when it
      // reopens the gate (see [_applyConsentResultOnce]); recovery reopens the
      // same gate, so it owes the same refill. Mounted banners come back on
      // their own via `canRequestAdsListenable`, but the fullscreen slots
      // would otherwise idle until the next route change or periodic scan.
      _retryRefillAds();
    } catch (e, st) {
      // Round-14 QC, MAJOR — the UMP read is not the only thing here that can
      // throw: the TCF read is a platform-store lookup and the mismatch
      // re-apply writes to both providers. Any of those failing has exactly
      // the consequence the UMP `catch` above exists to prevent — the debt
      // stays armed with nobody coming back for it — so it retries the same
      // bounded way instead of only being logged.
      SafeLogger.e(
          _tag, '🔐 consent gate recovery failed after the UMP read: $e\n$st');
    } finally {
      // Round-15 QC, MAJOR — one owner for the debt, at the only place every
      // path goes through. Whatever happened above, the debt is either settled
      // or still owed; if it is still owed then this run was the last thing
      // that could have paid it, because the runs its own nested apply would
      // have kicked are suppressed by `_consentGateRecovering` for as long as
      // this one is on the stack. Leaving without a timer armed is what makes
      // a guessed close permanent — every ad surface dark for the session.
      _consentGateRecovering = false;
      if (_recoveryStillOwed && _consentGateRecoveryRetry?.isActive != true) {
        _scheduleConsentGateRecoveryRetry(knownTcfRefusal: knownTcfRefusal);
      }
    }
  }

  /// Whether this recovery run still owns the debt it set out to pay.
  ///
  /// Round-14 QC, MAJOR — when the epoch moved under one of its awaits a newer
  /// intent took over (a host `setConsent`, a `destroy()`), and this run must
  /// stand down. But standing down silently loses the debt: a host
  /// `setConsent` deliberately never touches `_canRequestAds`, so the guessed
  /// close it landed on top of would stay for the rest of the session. The
  /// `finally` in [_recoverConsentGate] is what hands such a debt to a bounded
  /// retry — this stays a pure predicate so there is exactly one place that
  /// decides to re-arm. A `destroy()` clears the flag, so nothing is armed.
  bool _consentRecoveryStillOwns(int epoch) {
    if (epoch == _consentIntentEpoch) return _recoveryStillOwed;
    if (_recoveryStillOwed) {
      SafeLogger.w(
          _tag,
          '🔐 consent gate recovery lost its epoch mid-flight but the gate is '
          'still shut on a guess — handing it to a retry');
    }
    return false;
  }

  /// Whether [_recoverConsentGate] still has a guessed close to lift. Read
  /// again after every await it makes — see the comment there.
  bool get _recoveryStillOwed =>
      _pessimisticGateClose &&
      !_canRequestAds &&
      !_footgunBlocked &&
      !_consentApplyRunning &&
      _pendingConsentApply == null;

  /// How long recovery waits on the UMP channel before treating it as a
  /// failure worth retrying.
  static const Duration _consentGateRecoveryTimeout = Duration(seconds: 10);

  /// Test-only shortening of [_consentGateRecoveryRetryDelay].
  @visibleForTesting
  static Duration? debugConsentGateRecoveryRetryDelay;

  static const Duration _consentGateRecoveryRetryDelay = Duration(seconds: 30);
  static const int _maxConsentGateRecoveryAttempts = 3;
  int _consentGateRecoveryAttempts = 0;
  Timer? _consentGateRecoveryRetry;

  void _scheduleConsentGateRecoveryRetry({bool knownTcfRefusal = false}) {
    if (_consentGateRecoveryAttempts >= _maxConsentGateRecoveryAttempts) {
      SafeLogger.e(
          _tag,
          '🔐 consent gate recovery gave up after '
          '$_consentGateRecoveryAttempts attempts — ads stay blocked until the '
          'next consent decision or app resume');
      return;
    }
    _consentGateRecoveryAttempts++;
    _consentGateRecoveryRetry?.cancel();
    _consentGateRecoveryRetry = Timer(
        debugConsentGateRecoveryRetryDelay ?? _consentGateRecoveryRetryDelay,
        () {
      unawaited(_recoverConsentGate(knownTcfRefusal: knownTcfRefusal)
          .catchError((Object e) {
        SafeLogger.w(_tag, '_recoverConsentGate retry threw: $e');
      }));
    });
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

  /// Test-only barrier awaited right before `setConsent()`'s own tail write
  /// to the native provider (the epoch-guarded call added by the round-38
  /// MAJOR fix) — lets an integration test hold one call's write open while
  /// a newer, overlapping `setConsent()` call lands underneath it, without
  /// needing to fight real platform-channel FIFO ordering to reproduce the
  /// race. Purely a Dart-side delay: the write it guards is still the real
  /// call into the real native SDK once released.
  @visibleForTesting
  static Future<void>? debugSetConsentTailWriteBarrier;

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
    if (!result.canRequestAds) {
      _updateCanRequestAds(false);
    } else if (!hasConsent && appliedBefore.hasUserConsent) {
      _updateCanRequestAds(false);
      // Round-17 QC, MAJOR — this close is owed a reopen and had no owner. The
      // decision itself is real (personalisation off), but it still leaves ads
      // ALLOWED, so the gate must come back once the write lands. It did not
      // when the write was superseded by a host `setConsent` or threw: both
      // return before the reopen below, `setConsent` deliberately never touches
      // `_canRequestAds`, and nothing had armed the debt — so every ad surface
      // in the app stayed dark for the rest of the session. Same debt the
      // queued close arms; [_recoverConsentGate] pays it.
      _pessimisticGateClose = true;
      _consentGateRecoveryAttempts = 0;
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

  /// Round-20 QC, BLOCKER — how long a *tighten* may wait for UMP before going
  /// ahead without it. Well inside [_resumeConsentRecheckTimeout] on purpose:
  /// the caller's own cap must never be the thing that stops a withdrawal from
  /// reaching the providers.
  static const Duration _deviceWithdrawalUmpTimeout = Duration(seconds: 2);

  /// Round-20 QC, BLOCKER — apply a withdrawal the device's own TCF keys
  /// already report, with or without a UMP answer to go on.
  ///
  /// Whether ads may be PERSONALISED is `statusAllows && tcfAllows`, so a
  /// refusal in the TCF keys settles that half on its own; UMP is only ever
  /// consulted for whether ads may be requested AT ALL. Both callers used to
  /// read UMP FIRST and give up when it failed, so a device with no network —
  /// or a UMP outage, which is a real thing on hardware: `2:Error making
  /// request.`, reproduced on a Pixel 7 Pro — kept the personalised
  /// configuration on both providers for the whole session. That is the exact
  /// violation the resume backstop and the init reconcile exist to prevent,
  /// and the one direction that must never depend on a network round-trip.
  ///
  /// [ump] is whatever answer we did manage to get, or null. Without one the
  /// ad gate is left exactly as it is rather than guessed either way: this
  /// path only ever tightens personalisation, and widening `canRequestAds`
  /// without evidence is what the recovery debt is for.
  Future<void> _applyDeviceWithdrawal(UmpConsentResult? ump) async {
    final result = PrivacyOptionsResult(
      canRequestAds: ump?.canRequestAds ?? _canRequestAds,
      // Round-20 QC (codex), BLOCKER — deliberately NOT `ump.status`, even when
      // UMP answered. Every caller of this method has already read a TCF
      // refusal off the device, and `unknown` is the one status
      // [_umpStatusAllowsPersonalisation] maps to "personalisation not
      // allowed" — so the withdrawal is settled by what we read, not by the
      // pipeline's own second TCF read. That read can throw or come back null
      // (`gdprApplies` cleared under us, a storage error), and `null` means
      // "assume allowed": a re-apply that was supposed to carry a withdrawal
      // used to come back out of the pipeline as a GRANT, leaving both
      // providers personalised under a refusal.
      //
      // `canRequestAds` above still comes from UMP: personalisation is off,
      // but non-personalised ads may keep serving, and the pipeline's own
      // tighten branch closes the gate for the duration of the write and arms
      // the recovery debt that reopens it.
      status: ConsentStatus.unknown,
    );
    await _applyPrivacyOptionsResult(result);
    // Round-20 QC — reached with the gate ALREADY shut (the init reconcile shut
    // it, then handed the re-apply here), this apply tightens rather than
    // reopens, and every deliberate gate write clears the debt flag — see
    // [_updateCanRequestAds]. So re-arm it: nothing else in the SDK ever sets
    // `_canRequestAds` back to true, and a debt with no owner is a shut gate
    // for the rest of the session. Safe even if the close turns out to be a
    // real restrictive one: [_recoverConsentGate] settles that itself the next
    // time UMP answers `canRequestAds: false`.
    if (!result.canRequestAds && !_canRequestAds) {
      _pessimisticGateClose = true;
    }
  }

  /// Round-25 QC round 21 (`codex`, MAJOR) — carry the device's own CCPA /
  /// US-states "do not sell or share" opt-out into the consent state BOTH
  /// providers read.
  ///
  /// The signal was already being read ([usPrivacyOptedOut], written to
  /// `IABUSPrivacy_String` by whatever CMP the host runs) but it was only ever
  /// *reported*: `AdConsent.doNotSell` was writable by the host and by nothing
  /// else, so a Californian who opted out through a CMP still had AppLovin's
  /// `setDoNotSell(false)` and AdMob's `restricted_data_processing` unset
  /// unless the host separately noticed and called [setConsent] itself. m10
  /// (round-5 audit) found the same gap and fixed only the compliance report;
  /// this is the enforcement half.
  ///
  /// Tighten-only, exactly like the TCF reconcile in [_recheckConsentOnResume]:
  /// `null` means the CMP wrote no string at all (the normal case outside the
  /// US) and `false` means the user did NOT opt out — neither is authority to
  /// clear a `doNotSell` the host set deliberately.
  ///
  /// Goes through [ConsentManager.set] rather than [setConsent] on purpose:
  /// `set` persists, applies to both providers, and notifies
  /// [_syncConsentToAdapter] (which discards the ads already cached under the
  /// looser state — the `doNotSell` false→true transition is one of the three
  /// axes it treats as a downgrade). [setConsent] would additionally bump
  /// `_consentIntentEpoch` and record a *host* intent, which this is not: it
  /// would cancel a consent apply still in flight and rewrite that apply's
  /// `hasUserConsent` from a value read before it landed.
  Future<void> _reconcileDeviceUsPrivacy() async {
    final optedOut = await IabStorage.usPrivacyOptedOut();
    if (optedOut != true) return;
    // Re-read `_consentManager` AFTER the await, and check the applied value
    // here rather than at the top: `destroy()` nulls it (rounds 19-20 — the
    // guard belongs immediately before the write, not at the door), and a
    // consent apply that landed during the read may already carry the opt-out.
    final mgr = _consentManager;
    if (mgr == null || mgr.current.doNotSell) return;
    SafeLogger.w(
        _tag,
        '🔐 device US Privacy string reports a sale opt-out — applying '
        'doNotSell to both providers');
    await mgr.set(mgr.current.copyWith(doNotSell: true), config: _config);
  }

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
    // Round-25 QC round 21 — before the TCF read, not inside it: a CCPA opt-out
    // is a different string from the TCF one, and the block below returns early
    // whenever there is no TCF data at all (every US user).
    await _reconcileDeviceUsPrivacy();
    final tcfAllows = await IabStorage.tcfAllowsPersonalisedAds();
    // No TCF data at all (the normal non-EEA case) — nothing to compare
    // against, and UMP alone is already the whole answer there.
    if (tcfAllows == null) return;
    final applied = _committedConsent;
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

    // Round-20 QC (codex), BLOCKER — captured BEFORE the UMP await below. A
    // host `setConsent` (a parental toggle, a CCPA switch) that lands while we
    // wait is a newer decision than this re-apply, and the apply pipeline
    // re-reads the TCF keys for itself — so if they had flipped permissive by
    // then, this "withdrawal" came back out of the pipeline as a GRANT written
    // over the host's own stricter value. The host's value is already applied
    // by `setConsent` itself, so standing down is all that is needed.
    final epoch = _consentIntentEpoch;
    // Round-20 QC, BLOCKER — bounded, and the withdrawal lands either way. An
    // unbounded read here was cut by [_resumeAdWorkAfterConsent]'s 5s cap (or
    // threw outright, offline), and the whole re-apply went down with it — so
    // the withdrawal survived as personalised ads for the rest of the session.
    // See [_applyDeviceWithdrawal].
    UmpConsentResult? ump;
    try {
      ump = await core_ump
          .recheckUmpConsentStatus()
          .timeout(_deviceWithdrawalUmpTimeout);
    } catch (e) {
      SafeLogger.w(
          _tag,
          '🔐 resume: UMP could not be reached ($e) — applying the device '
          'withdrawal without it');
    }

    if (epoch != _consentIntentEpoch) {
      SafeLogger.w(
          _tag,
          '🔐 resume: a host consent decision landed while this re-check was '
          'reading the device (epoch=$epoch, now=$_consentIntentEpoch) — '
          'standing down, the host value is the newer one');
      return;
    }

    SafeLogger.w(
        _tag,
        '🔐 resume: device consent state disagrees with what is applied '
        '(TCF personalisation=$tcfAllows, UMP status=${ump?.status.name}, '
        'applied hasUserConsent=${applied.hasUserConsent}) — re-applying');
    await _applyDeviceWithdrawal(ump);
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

  /// Non-null while [destroy] is running its own (awaiting) teardown. See
  /// [initialize], which waits on it rather than racing it.
  Future<void>? _destroyInFlight;

  bool _ownsCrashGuard = false;

  /// Test seam: whether a teardown is currently in flight.
  @visibleForTesting
  bool get debugDestroyInFlight => _destroyInFlight != null;

  /// Tears the SDK down. Serialised against itself and against [initialize]:
  ///
  /// Round-25 QC round 7 (`codex` MAJOR, `agy` MAJOR) — the teardown below
  /// awaits (the event stream close, the adapter's own `dispose()`), and
  /// everything after those awaits is written on the assumption that no new
  /// session exists. A host that called `initialize()` inside that window got a
  /// session built and then gutted by this method's own remaining lines: its
  /// adapter disposed, and — because `_ensureObserverAdded()` saw the old
  /// observer still registered and did nothing — its lifecycle observer
  /// removed, which silently kills App Open on resume for the rest of the
  /// process. Rather than sprinkling generation checks over every line of the
  /// teardown (three rounds of exactly that is what got us here), a new
  /// `initialize()` simply waits for the teardown to finish.
  Future<void> destroy() async {
    final pending = _destroyInFlight;
    if (pending != null) {
      SafeLogger.d(
          _tag,
          'destroy() while a teardown is already running — '
          'waiting for it instead of tearing down twice');
      await pending;
      // Round-25 QC round 8 (`codex` and `agy`, independently, MAJOR) — and
      // then *return*, which is what the log line above always claimed.
      // Without this the second caller fell through and ran a whole second
      // teardown after the first one had finished. That is not merely
      // redundant: the host's own `destroy()`-then-`initialize()` sequence can
      // interleave into the gap, so the redundant teardown bumped `_initGen`,
      // drained the queue with `false` and disposed the adapter *of the new
      // session* — the silently-dead-ads bug this whole serialisation exists
      // to stop. Coalescing is the correct semantic anyway: what this caller
      // asked for was "tear the running session down", and the teardown it
      // just awaited did exactly that. A session started afterwards is a
      // session it never saw.
      return;
    }
    final done = Completer<void>();
    _destroyInFlight = done.future;
    // Round-25 QC round 13 — `_destroyInFlight` is now an input to
    // `_fullscreenBusyReason`, so the public `fullscreenBusy` mirror has to be
    // recomputed on both edges or a host's "ads busy" UI would lie for the
    // length of the teardown (and stay stale after it).
    _recomputeFullscreenBusy();
    try {
      await _destroy();
    } finally {
      _destroyInFlight = null;
      done.complete();
      _recomputeFullscreenBusy();
    }
  }

  Future<void> _destroy() async {
    SafeLogger.d(_tag, 'destroy() called');
    // Round-25 QC round 5 (`codex`, BLOCKER) — invalidate any attempt still
    // running. Without the bump, an `initialize()` parked on native init
    // resumed after this teardown and installed an adapter, timers and a
    // connectivity watch into the torn-down SDK, then reported success. See
    // [_initSuperseded].
    _initGen++;
    if (_ownsCrashGuard) {
      uninstallAdCrashGuard();
      _ownsCrashGuard = false;
    }
    // A host tearing the SDK down while an init is still in flight would
    // otherwise leave anyone parked by the duplicate guard waiting on a
    // callback nothing will ever fire.
    _drainQueuedInitCallbacks(false);
    // Round-25 QC round 7 — released HERE, next to the drain, not a hundred
    // lines further down where it used to be. Everything between the two
    // points awaits, and a host calling `initialize()` in that window used to
    // see "init in progress" and park behind a queue that had just been
    // drained, on an attempt that is now abandoned — a callback that never
    // fires. The attempt this flag belonged to is already invalidated by the
    // `_initGen` bump above; the outer `finally` of `initialize()` is
    // gen-guarded, so it cannot set it back to `false` under a newer attempt.
    _isInitializing = false;
    // Round-25 QC round 10 (`agy`, MINOR) — stopped HERE, above this
    // teardown's first await, not a hundred lines below it. Both are pure
    // stop calls, so nothing between the two points needs them alive, and
    // `isInitialised` is `_config != null && _adapter != null` — both of
    // which stay non-null until well past `await _eventStream.close()`. So
    // the `!isInitialised` guard inside `_scheduleNextRetry` does NOT cover
    // this window: a poll tick landing in it passes every guard and refills
    // ads into an adapter this teardown is about to dispose. Not
    // independently pinnable without a real 5-minute delay (`_retryIntervalMs`
    // is a `static const` with no seam) — the paused-subscription trick can
    // hold the teardown open that long, but not cheaply enough for the suite.
    _stopAdRetryTimer();
    _stopConnectivityWatch();
    // Round-25 QC round 11 (`codex`, MAJOR) — the resume path is disarmed here
    // too, for exactly the same reason and with the same evidence. The
    // observer used to be removed at the very END of `_destroy()` and
    // `_resumeFallbackTimer` cancelled only inside `_resetGuardState()`, which
    // is later still. Both sit after the awaits below, and across those awaits
    // `_adapter` and `_config` are untouched — so the resume path's own guards
    // (`identical(_adapter, ad)`, `isInitialised`) all still pass. A user
    // returning to the app while a teardown was in flight could therefore be
    // shown an App Open ad on top of an SDK being dismantled: a policy
    // violation, and a native call into an adapter about to be disposed.
    if (_isObserverAdded) {
      WidgetsBinding.instance.removeObserver(this);
      _isObserverAdded = false;
    }
    _resumeFallbackTimer?.cancel();
    _resumeFallbackTimer = null;
    // Round-25 QC round 8 (`agy`, MAJOR) — the pending init retry is killed
    // here, *before* this teardown's first await, and its stranded caller is
    // answered on the spot. Two reasons for the position:
    //
    //  * the callback the retry timer holds is not in `_queuedInitCallbacks`
    //    (it never parked — it owns its attempt), so the drain above cannot
    //    cover it, and cancelling a `Timer` throws its closure away. Without
    //    this the caller was never answered at all, and a splash awaiting it
    //    sat there until its own hard-cap timer fired.
    //  * self-audit after round 8: cancelling further down (where this used to
    //    live) leaves the timer armed across `_eventStream.close()` and
    //    `_disposeAdapter()`. A retry firing in that window sees
    //    `_destroyInFlight != null`, waits the teardown out (round 7) and only
    //    then takes its generation — so `_initGen` cannot supersede it, and it
    //    quietly rebuilds a whole session the host had just torn down. Narrow
    //    (a pending retry implies no live adapter, which makes the teardown
    //    short) but free to close: nothing between here and the old position
    //    can re-arm the timer, because both `_scheduleInitRetryIfNeeded` call
    //    sites sit behind an `_initSuperseded` early return.
    _initRetryTimer?.cancel();
    _initRetryTimer = null;
    _initRetryAttempts = 0;
    final strandedByTeardown = _pendingRetryOnComplete;
    _pendingRetryOnComplete = null;
    if (strandedByTeardown != null) {
      SafeLogger.w(
          _tag,
          'destroy() cancelled a pending init retry — answering its caller '
          'false instead of leaving it waiting');
      try {
        strandedByTeardown(false, _currentDeviceGAID);
      } catch (e, st) {
        SafeLogger.e(_tag, 'host onComplete(false) threw: $e\n$st');
      }
    }
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
    // Round-13 QC (round 13) — and the recovery debt belongs to the session
    // that took it on; its retry must not fire into a torn-down one.
    _consentGateRecoveryRetry?.cancel();
    _consentGateRecoveryRetry = null;
    _consentGateRecoveryAttempts = 0;
    _pessimisticGateClose = false;
    // M2 — cleared HERE only, never in `_disposeAdapter()`: surviving adapter
    // teardown is precisely what makes the COPPA re-init path in setConsent()
    // reachable after a child-directed abort.
    _lastKnownConfig = null;
    _lastAppliedConsent = null;
    // Round-18 QC — the next session re-applies consent to the providers from
    // its own bootstrapped state (see `applyToProviders` in [initialize]), so a
    // record from this one says nothing about the next; and leaving it set
    // would leak across tests.
    resetLastConsentAppliedToProviders();
    // Round-25 QC round 11 (`codex`, BLOCKER) — bounded, never open-ended. A
    // host subscription to the public `events` stream may legally be *paused*
    // (a route transition, backpressure, a listener parked by the framework).
    // A paused subscriber buffers the done event, so `close()`'s future does
    // not complete until it resumes — and an unbounded `await` here hung the
    // whole teardown for as long as that took, i.e. possibly forever. While it
    // hung, `_destroyInFlight` was already published, so every later
    // `initialize()` parked behind it: one paused listener bricked the SDK for
    // the rest of the process. The wait is kept (a live listener should still
    // get its done event, and the ordering matters for hosts that clean UI up
    // on it) but capped.
    await _eventStream.close().timeout(
          const Duration(seconds: 2),
          onTimeout: () => SafeLogger.w(
              _tag,
              'the events stream did not finish closing within 2s — a paused '
              'subscriber is holding the done event. Continuing the teardown '
              'without it rather than hanging destroy() forever'),
        );
    _eventStream = StreamController<AdEvent>.broadcast();
    await _disposeAdapter();
    // Bump revision so subscribed widgets rebuild against the now-null adapter
    // (otherwise BannerAdWidget would keep painting the stale provider's view
    // until something else triggers a rebuild).
    initRevision.value = initRevision.value + 1;
    AdLoadingDialog.resetState();
    // Round-7 final QC put a `resetUmpFormOnScreen()` here, on the grounds
    // that a form counter left standing would carry its ad block across the
    // teardown into the next initialize().
    //
    // Round-13 QC (round 11), MAJOR — removed. `destroy()` does not dismiss a
    // native form (the same fact the consent session epoch exists for), so a
    // form put up before this teardown can still be on screen after the next
    // initialize() — and dropping its ad block is what lets an App Open ad
    // draw straight over a live consent form. The leak the old reset guarded
    // against is now bounded by each presentation's own 15-minute backstop
    // ([kUmpFormOnScreenBackstop]), which did not exist when it was written.
    //
    // Round-37 audit MAJOR — `AdScreenRouteLogger.resetState()` used to run
    // right here too, and it is exactly the same mistake: destroy() doesn't
    // dismiss a real dialog/popup route either (it isn't a Flutter route
    // this teardown owns), so zeroing `popupDepth` unconditionally made
    // `isDialogOnTop` lie `false` while that dialog was still genuinely on
    // screen — letting an App Open ad on the next resume stack right on top
    // of it, the identical failure mode the round-13 removal above was
    // written to prevent. `AdScreenRouteLogger` stays registered on the
    // host's `Navigator` across a destroy()/initialize() cycle (it is added
    // once in `navigatorObservers`, not re-created per cycle), so its count
    // keeps tracking real push/pop callbacks on its own without any manual
    // reset here. `resetState()` itself is left in place for the genuine
    // stale-state case (test isolation across a shared Dart isolate; a crash
    // recovery path that does not go through this teardown) — it is simply
    // no longer this method's job to call it.
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
    _revenueIntegrityLedger?.dispose();
    _revenueIntegrityLedger = null;
    _fillRateBaselineMonitorGen++;
    _fillRateBaselineMonitor?.dispose();
    _fillRateBaselineMonitor = null;
    // T136 (round 3 review, MAJOR/blocking) — capture BEFORE nulling the
    // fields, not after: the previous round put the awaited dispose()
    // calls below (right before `_resetGuardState()`), by which point
    // these two fields were ALREADY null from right here, making
    // `await _waterfallTuner?.dispose()` an unconditional no-op
    // (`await null` on an already-null field) — the exact bug this
    // capture avoids. `_resetGuardState()` further down still nulls
    // these fields too (needed for its other callers); disposing the
    // same instance twice is harmless (cancelling an already-null
    // subscription, re-awaiting the same settled write-chain Future).
    final tunerToFlush = _waterfallTuner;
    _waterfallTuner = null;
    final observerToFlush = _selfHealingObserver;
    _selfHealingObserver = null;
    _journeyPrefetcher?.dispose();
    _journeyPrefetcher = null;

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
    _offlineNotifier.value = false;
    // T136 (round 2 review, MAJOR) — `_resetGuardState()` below disposes
    // whatever is still non-null too, but that call is synchronous and
    // cannot await the bounded flush WaterfallTuner/SelfHealingObserver's
    // own `dispose()` now does — without awaiting the CAPTURED locals
    // here, a real destroy() (a real app process teardown included)
    // could lose whatever sample/dedupe write was still in flight.
    await tunerToFlush?.dispose();
    await observerToFlush?.dispose();
    _resetGuardState();

    // T70 — same reasoning as vipManager/consentManager/arbitrator above: a
    // stale _eventLog left alive past destroy() would keep being flushed
    // (didChangeAppLifecycleState's paused handler calls flush() whenever
    // _eventLog is non-null) and mix pre-destroy events into whatever
    // provider initialize() brings up next. Flush first so nothing queued
    // in its debounce window is lost.
    //
    // T102 — this used to be `unawaited(...)`. A host that calls
    // initialize() right after destroy() constructs a brand-new AdEventLog
    // over the same AdPreferences, whose constructor reads the persisted
    // blob synchronously off whatever's on disk right now — if the old
    // log's write hadn't landed yet, the new log silently lost the old
    // log's queued entries. Awaiting here closes that gap for real. (The
    // fix's first two attempts made `flutter test` hang on
    // ad_manager_core_test.dart — that was a test bug, `fakeAsync` mixed
    // with real platform-channel work in a different test; see that test's
    // own comment and git history for `test/destroy_awaits_event_log_flush_test.dart`.)
    //
    // Round-27 audit (3 independent reviewers, same finding) — same reasoning
    // as the `_eventStream.close()` timeout just above: an unbounded await on
    // a platform-channel write means a stuck SharedPreferences call would
    // hang destroy() forever, and every later initialize() parks behind it
    // via `_destroyInFlight`. Bounded, same as the other teardown waits.
    await _eventLog?.flush().timeout(
          const Duration(seconds: 2),
          onTimeout: () => SafeLogger.w(
              _tag,
              'event log flush did not finish within 2s — continuing teardown '
              'without waiting further rather than hanging destroy() forever'),
        );
    _eventLog = null;
    // T155 — deliberately NOT also flushed here (unlike _eventLog above).
    // An earlier version awaited bypassAuditTrail.flush().timeout(2s) at
    // this exact point and it reproduced a genuine multi-minute hang in
    // test/ad_manager_core_test.dart's full-file run (bisected: removing
    // just this call made the hang disappear; the trail's own attach()/
    // record()/persistence logic was not the cause). The debounced write
    // (1s window) plus the didChangeAppLifecycleState flush below already
    // cover the realistic loss window — a real process kill is normally
    // preceded by the app being backgrounded, not by a bare destroy() call
    // immediately followed by termination.
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
    _invalidateCoalescedLoads();
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
    // Round-14 QC, MINOR — same rule as the two timers above: a re-init
    // without destroy() must not leave a previous session's recovery retry
    // armed. It is a no-op when it fires (the reset reopened the gate, which
    // clears the debt), but a guard timer outliving its session is exactly
    // what the T63/round-5 entries above were about.
    _consentGateRecoveryRetry?.cancel();
    _consentGateRecoveryRetry = null;
    _consentGateRecoveryAttempts = 0;
    // Round-27 backlog B7 — same rule again: round-26 only cancelled these
    // two inside destroy()'s own inline block, so a reinit-without-destroy()
    // (initialize() called again while already initialised — the
    // "auto-disposing previous" branch, which only calls this function) left
    // a scheduled consent-dialog Timer capturing the OLD AdConfig/
    // ConsentManager alive into the new session, or `_consentDialogScheduled`
    // stuck `true` forever if the dialog had already been skipped once.
    // Moved here so BOTH entry points clean up through the one function this
    // class's own comment above already calls "single source of truth" for
    // exactly this class of bug.
    _consentDialogScheduled = false;
    _consentDialogTimer?.cancel();
    _consentDialogTimer = null;
    // T137 — same rule as every Timer field above: a reinit-without-
    // destroy() (this function's other caller) must not leave the PREVIOUS
    // session's periodic refresh still ticking against whatever provider/
    // config the new session set up. initialize() itself starts a fresh one
    // right after this call if the new session asked for one.
    _remoteSafetyRefreshTimer?.cancel();
    _remoteSafetyRefreshTimer = null;
    // T137 (round 2) — cleared alongside the timer above, not left to leak
    // into a new session: `_applyRemoteOverridesWithRevisionGuard`'s `??
    // prefs.getRemoteSafetyRevision()` fallback re-seeds it lazily from
    // persisted storage the next time it's actually needed, so this does
    // NOT lose cross-restart rollback protection — it only forgets an
    // in-memory value that a new session has no business inheriting from
    // whatever session used it last (a fresh `AdManager()` test double, or
    // this same singleton reinitialised without destroy()).
    _lastAppliedRemoteSafetyRevision = null;
    // Audit fix: a stale GAID from the previous session used to survive
    // destroy()/re-init, so currentDeviceGaid (and adMobTestDeviceHashHint())
    // could report a device's ad ID after the SDK claimed to be torn down —
    // a privacy leak past the point consent should be re-evaluated at.
    if (_currentDeviceGAID.isNotEmpty) {
      SafeLogger.d(_tag, 'resetGuardState: clearing stale GAID');
    }
    _currentDeviceGAID = '';
    // T160 — [_lastShownPlacement]'s own doc comment says "never cleared",
    // but that's about WITHIN a live session (a slightly-late paid event
    // still naming the last real show of that format is the right answer
    // there). This is the opposite case: BOTH callers of this method cross
    // a session boundary (a real destroy(), or `initialize()` called again
    // while already initialised) — a stale placement from the OLD
    // session's last show must not get attributed to a revenue event the
    // NEW session's adapter reports before its own first show call. Every
    // other per-session field in this method follows the same reset-on-
    // session-boundary rule.
    _lastShownPlacement.clear();
  }

  /// Test seam for [_resetGuardState] — exercised directly by
  /// ad_manager_core_test.dart since a real reinit-without-destroy() can't
  /// be driven through `initialize()` under `flutter test` (no native
  /// adapter).
  @visibleForTesting
  void debugResetGuardState() => _resetGuardState();

  /// Test seam — round-27 backlog B7 regression proof.
  @visibleForTesting
  bool get debugConsentDialogTimerActive => _consentDialogTimer != null;

  /// Round-26 audit (MAJOR, claude, borders BLOCKER) — `_disposeAdapter()`
  /// used to null the adapter's native listeners with no regard for a
  /// fullscreen ad actively on screen. For AppLovin specifically, the native
  /// bridge dereferences its listener at DISPATCH time rather than at
  /// show-start, so a reward event already in flight when teardown started
  /// landed on a listener that had just been nulled and was silently
  /// dropped — a user who finished watching a rewarded ad right as
  /// `destroy()` ran (provider switch, logout, SDK reset) was told they
  /// earned nothing despite having watched the whole thing. Give an
  /// in-flight show a bounded window to resolve on its own (dismiss or
  /// reward) before tearing the adapter down under it. Bounded, not
  /// unconditional: a wedged native SDK (the AdMob rewarded-stuck bug this
  /// package's own README documents) must never make `destroy()` hang.
  static const Duration _fullscreenShowDrainTimeout = Duration(seconds: 5);

  Future<void> _waitForFullscreenShowsToFinish(AdProviderAdapter ad) async {
    final List<AdSlot> showing;
    try {
      showing = [
        ad.appOpenSlot,
        ad.interstitialSlot,
        ad.rewardedSlot,
        ad.rewardedInterstitialSlot,
      ].where((s) => s.isShowing).toList();
    } catch (e) {
      // A slot getter throwing mid-teardown is an adapter bug in its own
      // right (already tolerated elsewhere in this method) — nothing to
      // wait on if we can't even read the state.
      SafeLogger.w(_tag, 'destroy(): slot read threw before drain wait: $e');
      return;
    }
    if (showing.isEmpty) return;
    SafeLogger.d(
        _tag,
        'destroy(): waiting up to ${_fullscreenShowDrainTimeout.inSeconds}s '
        'for ${showing.length} showing slot(s) to finish before teardown');
    final done = Completer<void>();
    void checkDone() {
      if (showing.every((s) => !s.isShowing) && !done.isCompleted) {
        done.complete();
      }
    }

    final attached = <AdSlot, VoidCallback>{};
    for (final slot in showing) {
      void listener() => checkDone();
      attached[slot] = listener;
      slot.state.addListener(listener);
    }
    final timer = Timer(_fullscreenShowDrainTimeout, () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      timer.cancel();
      for (final entry in attached.entries) {
        try {
          entry.key.state.removeListener(entry.value);
        } catch (_) {
          // Slot may already be disposed by a concurrent teardown path —
          // nothing left to detach from.
        }
      }
    }
  }

  Future<void> _disposeAdapter() async {
    final old = _adapter;
    if (old != null) {
      await _waitForFullscreenShowsToFinish(old);
      // Round-25 QC round 2 (both independent reviewers, MAJOR) — the teardown
      // is best-effort, the state change is NOT. A throw in here (a native
      // plugin's `dispose()`, a slot listener removal) used to skip the two
      // null-outs below, so `isInitialised` (== `_config != null && _adapter
      // != null`) kept answering `true` for an adapter the SDK had just torn
      // down — including on the path that had already told the host init
      // FAILED. Every caller depends on the fields being cleared and none of
      // them can do anything about a plugin that throws on the way out, so the
      // clearing happens regardless.
      // Round-25 QC round 3 (`codex`) — each step gets its own guard, not one
      // around all three. Sharing a guard meant a slot getter or a listener
      // removal that threw ALSO skipped `old.dispose()`, so the native adapter
      // was never told to go away: a leak on the one path where the SDK knows
      // something is already wrong with that adapter.
      try {
        old.appOpenSlot.state.removeListener(_onAppOpenStateChange);
      } catch (e) {
        SafeLogger.w(_tag, 'detaching the app-open listener threw: $e');
      }
      try {
        _detachFullscreenDismissWatchers();
      } catch (e) {
        SafeLogger.w(_tag, 'detaching the fullscreen watchers threw: $e');
      }
      try {
        // Round-29 audit (BLOCKER) — the only unbounded native
        // platform-channel await left in this teardown path; its two
        // siblings a few dozen lines below (`_eventStream.close()`,
        // `_eventLog?.flush()`) both got a 2s timeout in round 27 for the
        // exact same reason: a hang here (not a throw — `catch` already
        // covered that) never returns, so `_destroy()` never returns,
        // `_destroyInFlight` never clears, and every future `initialize()`
        // waits on it forever.
        await old.dispose().timeout(const Duration(seconds: 2), onTimeout: () {
          SafeLogger.w(
              _tag, '⏱️ adapter dispose() timed out — proceeding anyway');
        });
      } catch (e) {
        SafeLogger.w(_tag,
            'the adapter dispose() threw — clearing SDK state anyway: $e');
      }
    }
    // Guarded for its own reason: the `_adapter` setter re-runs the fullscreen
    // busy-slot listener plumbing, which reads the OLD adapter's slot getters,
    // and a broken adapter can throw from there too. `_adapterField` is the
    // raw field behind the setter — last resort, so a throw here cannot leave
    // the SDK claiming to be initialised either.
    try {
      _adapter = null;
    } catch (e) {
      SafeLogger.e(
          _tag, 'detaching slot listeners threw — clearing the field raw: $e');
      _adapterField = null;
    }
    _config = null;
    _remoteSafetyProvider = null;
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
    if (_teardownBlocksLoad(AdSlotType.appOpen)) {
      onAdLoaded?.call(false);
      return;
    }
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
    if (AdSafetyConfig.isNetworkFatigued(AdSlotType.appOpen)) {
      SafeLogger.d(_tag, '⏭️ loadAppOpen skipped — network fatigue cooldown');
      _emitSkip(AdSlotType.appOpen, 'load', 'network_fatigue');
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
    // Internal lifecycle preloads intentionally keep their historical
    // fire-and-forget semantics (they do not have a caller callback). The
    // fan-out path is for explicit callers that need completion delivery.
    if (onAdLoaded == null) {
      await ad.loadAppOpen();
    } else {
      await _coalesceAppOpenLoad(ad, onAdLoaded);
    }
    _armLoadWatchdog('appOpen', ad.appOpenSlot, watchdog);
  }

  /// Round-25 QC round 12 (`codex`, MAJOR) — a teardown is not just "stop
  /// listening", it must also stop work that was ALREADY launched. Detaching
  /// the lifecycle observer in `_destroy()`'s prologue keeps the framework from
  /// delivering a *new* resume, but a resume that arrived a moment earlier has
  /// already opened `AdLoadingDialog.showAdBuffer`, and that buffer's
  /// `onComplete` fires ~500ms later — with `_adapter` and `_config` still
  /// live, so every guard inside it passes and a native App Open ad is shown on
  /// top of an SDK being dismantled. Guarding the buffer callback alone would
  /// fix the one path the reviewer found; this sits at the convergence point
  /// instead, so any other already-launched timer or callback that reaches a
  /// fullscreen show during a teardown is caught by the same check.
  /// Round-25 QC round 14 (`codex`, MAJOR) — the load-side twin of
  /// [_teardownBlocksShow]. A load starting inside a teardown reaches the
  /// native SDK, and its callback then lands on slots this teardown is about to
  /// dispose: at best a wasted ad request counted against the app's show rate,
  /// at worst a write to a disposed `ValueNotifier`. The show-side fix does not
  /// cover these — the four `loadX` methods read the private `_adapter`, not the
  /// public getter that now hides it.
  bool _teardownBlocksLoad(AdSlotType type) {
    if (_destroyInFlight == null) return false;
    SafeLogger.d(
        _tag, '⏭️ load ${type.name} skipped — a teardown is in flight');
    _emitSkip(type, 'load', 'teardown_in_flight');
    return true;
  }

  bool _teardownBlocksShow(AdSlotType type, AdPlacement placement) {
    if (_destroyInFlight == null) return false;
    SafeLogger.d(
        _tag, '⏭️ show ${type.name} skipped — a teardown is in flight');
    _emitSkip(type, 'show', 'teardown_in_flight', placement: placement);
    return true;
  }

  Future<void> showAppOpenAd({
    required void Function(bool dismissed) onAdDismiss,
    // Round-32 audit — flagged again as a footgun risk, kept as a public
    // param by design (splash needs to bypass the daily/hourly/session caps
    // and 60s throttle to show right after cold start). ⚠️ THIS IS NOT
    // TECHNICALLY RESTRICTED TO SPLASH — nothing in the SDK stops it being
    // called (or copy-pasted) from anywhere else in a host app, and doing so
    // would show App Open ads with no frequency limit, a real AdMob/AppLovin
    // placement-policy violation. `callSiteTag` below and `bypassAuditTrail`
    // record every call for later export, but that is an after-the-fact
    // audit trail (and in-memory only — cleared on app restart), not an
    // enforcement mechanism. Only call this with `true` from the splash
    // screen's own App Open show, per the integration contract in the
    // package README.
    bool bypassSafety = false,
    AdPlacement placement = AdPlacement.splash,
    // T128 — proof-of-compliance: identifies THIS call site in the signed
    // audit trail (see [bypassAuditTrail]). Purely descriptive, host-chosen;
    // not verified against anything — the point is a later export shows
    // every place this documented-as-splash-only back door was actually
    // invoked from, not that it enforces where it's allowed to be called.
    String callSiteTag = 'unspecified',
  }) async {
    // Independent review (round 37 verification) — set before onDismiss
    // runs, not after; see the catch block far below for why.
    var delivered = false;
    if (bypassSafety) {
      bypassAuditTrail.record(
        kind: 'bypassSafety',
        callSiteTag: callSiteTag,
        type: AdSlotType.appOpen,
      );
    }
    if (_teardownBlocksShow(AdSlotType.appOpen, placement)) {
      onAdDismiss(false);
      return;
    }
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
      final s = AdSafetyConfig.canShowFullscreenAd(
          forType: AdSlotType.appOpen,
          minIntervalOverrideMs:
              _placementMinIntervalOverride(placement, AdSlotType.appOpen));
      if (!s.canShow) {
        SafeLogger.d(
            _tag, () => '⏭️ showAppOpen blocked by safety: ${s.reason}');
        onAdDismiss(false);
        return;
      }
      // T92 — additional per-placement daily cap, same bypassSafety
      // exemption as the global cooldown check just above (a host that
      // opted out of ALL safety for this call shouldn't get half-exempted).
      if (AdSafetyConfig.placementDailyCapReached(placement,
          capOverride: _placementCapOverride(placement, AdSlotType.appOpen))) {
        SafeLogger.d(_tag,
            '⏭️ showAppOpen skipped — placement daily cap reached ($placement)');
        _emitSkip(AdSlotType.appOpen, 'show', 'placement_cap',
            placement: placement);
        onAdDismiss(false);
        return;
      }
    }
    // Sweep invariant — asked immediately before presenting, never at the door.
    // See [_presentBlockedReason]. No `await` sits above this today; the guard
    // is here so that the day one does, the hole does not reopen.
    final blocked = _presentBlockedReason(ad);
    if (blocked != null) {
      SafeLogger.w(_tag, '⏭️ showAppOpen skipped — $blocked');
      _emitSkip(AdSlotType.appOpen, 'show', 'blocked', placement: placement);
      onAdDismiss(false);
      return;
    }
    SafeLogger.d(
        _tag,
        () =>
            '▶️ showAppOpen (bypassSafety=$bypassSafety, placement=${placement.id})');
    // Round-23 QC (reviewer B, MAJOR) — Google's App Open guidance says not to
    // show an App Open ad on top of another ad, and names banner content. The
    // resume path had just restored banner visibility (`onAppResumed`) before
    // getting here, so a user coming back to a monetised screen got exactly
    // that placement: a fullscreen ad over a live banner. Blank the inline
    // surfaces for the duration instead of skipping the App Open — dropping it
    // would kill the format on every screen that carries a banner, which is
    // most of them.
    //
    // Round-28 QC (reviewer B, MINOR) — the backstop is `_armAppOpenShowTimeout`
    // (90 s hard cap, calls the captured `onDismiss`, which restores below) and
    // `dispose()`. NOT `onAppResumed`, as this said before visibility became
    // owned: a resume releases only the `background` owner and leaves the
    // `fullscreen` hold. The cap is the contract for a host adapter, not a
    // convenience.
    final inline = ad is InlineAdVisibility ? ad as InlineAdVisibility : null;
    inline?.setInlineAdsHidden(true);
    _lastShownPlacement[AdSlotType.appOpen] = placement;
    try {
      await ad.showAppOpen(onDismiss: (dismissed) {
        delivered = true;
        inline?.setInlineAdsHidden(false);
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
          // T185 — read BEFORE the reload below can overwrite it; see
          // AdSlot.requestId's doc comment for why this is still the
          // right value even though the slot is mutable.
          requestId: ad.appOpenSlot.requestId,
        ));
        onAdDismiss(dismissed);
        unawaited(loadAppOpenAd());
      });
    } catch (e, st) {
      // The show never got off the ground, so no dismiss callback is coming
      // from the native side.
      //
      // Round-37 audit (MAJOR) — this used to `rethrow`, which left whoever
      // awaited this call (typically the splash screen, per the documented
      // `showAdBuffer(...).onComplete` → `showAppOpenAd(bypassSafety: true)`
      // integration contract) with an unhandled exception AND a callback
      // that never fires — the exact failure class `showRewardedAd` was
      // hardened against in round-29. Resolve it the same way instead.
      SafeLogger.e(_tag, 'showAppOpenAd threw: $e\n$st');
      inline?.setInlineAdsHidden(false);
      // Independent review (round 37 verification) — only fall back if the
      // real callback never ran (see showInterstitial's identical guard).
      if (!delivered) onAdDismiss(false);
    }
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
    // T181 (codex round-1 fix) — AdPlacement.splash matches showAppOpenAd's
    // own default placement, which is what the subsequent successful-resume
    // show call below actually uses.
    final safetyResume = AdSafetyConfig.canShowAppOpenOnResume(
        minIntervalOverrideMs:
            _placementMinIntervalOverride(AdPlacement.splash, AdSlotType.appOpen));
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
    if (_teardownBlocksLoad(AdSlotType.interstitial)) return;
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
    if (AdSafetyConfig.isNetworkFatigued(AdSlotType.interstitial)) {
      SafeLogger.d(
          _tag, '⏭️ loadInterstitial skipped — network fatigue cooldown');
      _emitSkip(AdSlotType.interstitial, 'load', 'network_fatigue');
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
    await _coalesceAdLoad(AdSlotType.interstitial, ad.loadInterstitial);
    _armLoadWatchdog('interstitial', ad.interstitialSlot, watchdog);
  }

  /// Show an interstitial. [placement] tags the call for analytics
  /// (defaults to [AdPlacement.unspecified]).
  Future<void> showInterstitial({
    required void Function(bool shown) onDoneFlow,
    AdPlacement placement = AdPlacement.unspecified,
  }) async {
    if (_teardownBlocksShow(AdSlotType.interstitial, placement)) {
      onDoneFlow(false);
      return;
    }
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
    final safety = AdSafetyConfig.canShowFullscreenAd(
        forType: AdSlotType.interstitial,
        minIntervalOverrideMs:
            _placementMinIntervalOverride(placement, AdSlotType.interstitial));
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
    if (AdSafetyConfig.placementDailyCapReached(placement,
        capOverride:
            _placementCapOverride(placement, AdSlotType.interstitial))) {
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
        // Round-23 QC (reviewer A, MAJOR) — report the figure the veto was
        // actually made on: this slot's own trailing eCPM, not the
        // all-formats/all-currencies diagnostic average.
        estimatedEcpmMicros:
            arbitrator.estimatedEcpmMicrosFor(AdSlotType.interstitial),
      ));
      onDoneFlow(false);
      return;
    }
    // Sweep invariant — asked immediately before presenting, never at the door.
    // See [_presentBlockedReason]. No `await` sits above this today; the guard
    // is here so that the day one does, the hole does not reopen.
    final blocked = _presentBlockedReason(ad);
    if (blocked != null) {
      SafeLogger.w(_tag, '⏭️ showInterstitial skipped — $blocked');
      _emitSkip(AdSlotType.interstitial, 'show', 'blocked',
          placement: placement);
      onDoneFlow(false);
      return;
    }
    SafeLogger.d(
        _tag,
        () =>
            '▶️ showInterstitial (placement=${placement.id}, slot=${ad.interstitialSlot.value.name})');
    _lastShownPlacement[AdSlotType.interstitial] = placement;
    // Independent review (round 37 verification) — set BEFORE onDoneFlow
    // runs, not after: the catch below must not re-deliver a result once
    // the real callback has been entered, even if onDoneFlow (or something
    // else in this lambda) itself throws. Confirmed empirically that
    // without this, a throwing host callback was invoked twice with
    // contradictory results.
    var delivered = false;
    try {
      await ad.showInterstitial(onDone: (shown) {
        delivered = true;
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
          // T185 — read BEFORE the reload below can overwrite it.
          requestId: ad.interstitialSlot.requestId,
        ));
        onDoneFlow(shown);
        // Fix #1 (preserved from 1.x): reload after dismiss OR show-fail to
        // keep the slot filled for the next user-triggered show. AppLovin
        // adapter ALSO reloads internally; the dedup in
        // adapter.loadInterstitial (`isReady` / `isLoading` early-return)
        // makes the duplicate harmless.
        unawaited(loadInterstitial());
      });
    } catch (e, st) {
      // Round-37 audit (MAJOR) — a throw here (native platform-channel
      // exception, wedged native SDK) used to propagate straight out of
      // this method with `onDoneFlow` never called, matching the exact
      // failure `showRewardedAd` was hardened against in round-29.
      SafeLogger.e(_tag, 'showInterstitial threw: $e\n$st');
      // Independent review (round 37 verification) — only fall back here if
      // the real callback never ran. Otherwise this double-delivers: the
      // host already got its result, and re-invoking it with a different
      // one (e.g. because onDoneFlow itself threw) is worse than the
      // exception it produced.
      if (!delivered) onDoneFlow(false);
    }
  }

  /// T181 (codex round-1 fix) — [placement] defaults to
  /// [AdPlacement.unspecified], the same default [showInterstitial] itself
  /// uses, so an existing caller passing nothing sees exactly the same
  /// result as before this parameter existed (no registry entry for
  /// `unspecified` means no override, same as always). Pass the SAME
  /// [AdPlacement] you intend to hand [showInterstitial] — without this,
  /// a placement with a LOOSER `minIntervalOverrideMs` than the app-wide
  /// throttle would have this peek (used to gate a "Watch Ad" button in
  /// the documented `AdScreenState` pre-check pattern) say `false` while
  /// the real [showInterstitial] call for that same placement would have
  /// actually succeeded.
  bool canShowInterstitial({AdPlacement placement = AdPlacement.unspecified}) {
    final ad = _adapter;
    if (ad == null) return false;
    if (_isVipMember) return false;
    // T64 — a slot can finish loading+caching while consent was still
    // granted, then have consent revoked before the actual show call. Cache
    // readiness must not outlive consent.
    if (!canRequestAds) return false;
    if (ad.interstitialSlot.isShowing) return false;
    if (AdLoadingDialog.isShowing) return false;
    // Round-37 audit (MAJOR) — this peek is used as the pre-check before
    // showInterstitial() opens the SDK's own dialogs; missing this let a
    // second call land while a popup/dialog from another in-flight flow was
    // already on screen (see _fullscreenBusyReason, which the real show
    // path re-checks and which already covers this signal).
    if (AdScreenRouteLogger.isDialogOnTop) return false;
    // T168 — same reasoning, for a host's own custom overlay
    // (isDialogOnTop above cannot see it — see customOverlayOnScreen's doc
    // comment).
    if (customOverlayOnScreen.value) return false;
    // T137 forType — this peek gates interstitial specifically.
    // Peek, not canShowFullscreenAd() — this is a read-only "should I enable
    // my UI" query a host may poll repeatedly; the non-peek variant has a
    // CTR-anomaly side effect that would otherwise re-arm/escalate a
    // suspicious-pause window forever on every poll (2026-08-16 audit).
    final s = AdSafetyConfig.canShowFullscreenAdPeek(
        forType: AdSlotType.interstitial,
        minIntervalOverrideMs: _placementMinIntervalOverride(
            placement, AdSlotType.interstitial));
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
    if (_teardownBlocksLoad(AdSlotType.rewarded)) return;
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
    if (AdSafetyConfig.isNetworkFatigued(AdSlotType.rewarded)) {
      SafeLogger.d(_tag, '⏭️ loadRewarded skipped — network fatigue cooldown');
      _emitSkip(AdSlotType.rewarded, 'load', 'network_fatigue');
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
    await _coalesceAdLoad(AdSlotType.rewarded, ad.loadRewarded);
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
    // T128 — proof-of-compliance: same purpose as showAppOpenAd's
    // callSiteTag, for the OTHER documented back door (VIP watching a
    // rewarded ad to extend their own window).
    String callSiteTag = 'unspecified',
  }) async {
    if (bypassVipGuard) {
      bypassAuditTrail.record(
        kind: 'bypassVipGuard',
        callSiteTag: callSiteTag,
        type: AdSlotType.rewarded,
      );
    }
    if (_teardownBlocksShow(AdSlotType.rewarded, placement)) {
      onEarnedReward(false);
      return;
    }
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
    final safety = AdSafetyConfig.canShowFullscreenAd(
        forType: AdSlotType.rewarded,
        minIntervalOverrideMs:
            _placementMinIntervalOverride(placement, AdSlotType.rewarded));
    if (!safety.canShow) {
      SafeLogger.d(
          _tag, () => '⏭️ showRewarded blocked by safety: ${safety.reason}');
      _emitSkip(AdSlotType.rewarded, 'show', 'cooldown', placement: placement);
      onEarnedReward(false);
      return;
    }
    // T92 — additional per-placement daily cap, on top of (never instead
    // of) the global one just above.
    if (AdSafetyConfig.placementDailyCapReached(placement,
        capOverride: _placementCapOverride(placement, AdSlotType.rewarded))) {
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
        // Round-23 QC (reviewer A, MAJOR) — report the figure the veto was
        // actually made on: this slot's own trailing eCPM, not the
        // all-formats/all-currencies diagnostic average.
        estimatedEcpmMicros:
            arbitrator.estimatedEcpmMicrosFor(AdSlotType.rewarded),
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
      bool loaded;
      try {
        loaded = await _loadRewardedOnDemand(ad, timeout: onDemandLoadTimeout);
      } catch (e) {
        // Round-29 audit (BLOCKER) — `_loadRewardedOnDemand` awaits
        // `ad.loadRewarded()`, a real native platform-channel call with no
        // guaranteed-not-to-throw contract. Left unguarded, a throw here
        // (PlatformException, a disposed adapter mid-call) skipped every
        // `_rewardedInFlight = false` below and wedged every future
        // showRewardedAd() call for the rest of the process.
        if (shownOwnDialog) AdLoadingDialog.dismiss();
        _rewardedInFlight = false;
        SafeLogger.e(
            _tag, '⏭️ showRewarded (bypass) — on-demand load threw: $e');
        onEarnedReward(false);
        return;
      }
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
    // Round-25 QC round 22 (`codex`, BLOCKER) — the consent gate at the top of
    // this method is read BEFORE a load that can take `onDemandLoadTimeout`
    // (15s by default). A withdrawal that lands inside that window — the user
    // backgrounds the app, changes their answer in the CMP, comes back and the
    // resume re-check applies it — used to be ignored: only the fullscreen
    // mutex was re-read, so the ad was presented anyway. An impression served
    // after the user said no is the single outcome this SDK exists to prevent.
    //
    // The round-22 fix put a check inside the bypass branch. The sweep that
    // followed moved it here instead: this line is on BOTH paths through the
    // method (the bypass one after its on-demand load, and the ordinary one
    // after the VIP and safety awaits), it is the last statement before the
    // act, and there is exactly one of it to keep correct.
    final blocked = _presentBlockedReason(ad);
    if (blocked != null) {
      _rewardedInFlight = false;
      SafeLogger.w(_tag, '⏭️ showRewarded skipped — $blocked');
      _emitSkip(AdSlotType.rewarded, 'show', 'blocked', placement: placement);
      onEarnedReward(false);
      return;
    }
    SafeLogger.d(
        _tag,
        () =>
            '▶️ showRewarded (placement=${placement.id}, vipAutoGrant=$vipAutoGrant, slot=${ad.rewardedSlot.value.name})');
    _lastShownPlacement[AdSlotType.rewarded] = placement;
    // Independent review (round 37 verification) — the pre-existing
    // round-29 catch below unconditionally called `onEarnedReward(false)`,
    // even when the real `onDone` had already delivered a result and then
    // something inside it (or `onEarnedReward` itself) threw — a
    // double-delivery with a contradictory result. Confirmed empirically
    // (see the same fix applied to `showInterstitial` for the full
    // reasoning); `delivered` is set before `onEarnedReward` runs so the
    // catch never re-fires it once the real callback was entered.
    var delivered = false;
    try {
      await ad.showRewarded(
          ssvCustomData: ssvCustomData,
          ssvUserId: ssvUserId,
          onDone: (result) {
            delivered = true;
            _rewardedInFlight = false;
            if (result.shown) {
              AdSafetyConfig.recordFullscreenAdShown();
              AdSafetyConfig.recordPlacementAdShown(placement); // T92
            }
            if (result.earned) {
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
              success: result.shown,
              // T185 — read BEFORE the reload below can overwrite it.
              requestId: ad.rewardedSlot.requestId,
            ));
            onEarnedReward(result.earned);
            // Fix #2 (preserved from 1.x): reload after dismiss/fail. Same
            // dedup applies as for the interstitial path.
            unawaited(loadRewardedAd());
          });
    } catch (e) {
      // Round-29 audit (BLOCKER) — `ad.showRewarded()` is a real native
      // platform-channel call; if it throws instead of calling `onDone`,
      // `_rewardedInFlight` was never reset above and every future
      // showRewardedAd() call would report "busy" forever.
      _rewardedInFlight = false;
      SafeLogger.e(_tag, '⏭️ showRewarded — adapter call threw: $e');
      // Independent review (round 37 verification) — only fall back if the
      // real callback never ran (see above).
      if (!delivered) onEarnedReward(false);
    }
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
    if (_teardownBlocksLoad(AdSlotType.rewardedInterstitial)) return;
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
    if (AdSafetyConfig.isNetworkFatigued(AdSlotType.rewardedInterstitial)) {
      SafeLogger.d(_tag,
          '⏭️ loadRewardedInterstitial skipped — network fatigue cooldown');
      _emitSkip(AdSlotType.rewardedInterstitial, 'load', 'network_fatigue');
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
    await _coalesceAdLoad(
        AdSlotType.rewardedInterstitial, ad.loadRewardedInterstitial);
    _armLoadWatchdog(
        'rewardedInterstitial', ad.rewardedInterstitialSlot, watchdog);
  }

  Future<void> showRewardedInterstitialAd({
    required void Function(bool shown, bool earned) onDone,
    AdPlacement placement = AdPlacement.unspecified,
  }) async {
    if (_teardownBlocksShow(AdSlotType.rewardedInterstitial, placement)) {
      onDone(false, false);
      return;
    }
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
    final safety = AdSafetyConfig.canShowFullscreenAd(
        forType: AdSlotType.rewardedInterstitial,
        minIntervalOverrideMs: _placementMinIntervalOverride(
            placement, AdSlotType.rewardedInterstitial));
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
    if (AdSafetyConfig.placementDailyCapReached(placement,
        capOverride: _placementCapOverride(
            placement, AdSlotType.rewardedInterstitial))) {
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
        // Round-23 QC (reviewer A, MAJOR) — report the figure the veto was
        // actually made on: this slot's own trailing eCPM, not the
        // all-formats/all-currencies diagnostic average.
        estimatedEcpmMicros:
            arbitrator.estimatedEcpmMicrosFor(AdSlotType.rewardedInterstitial),
      ));
      onDone(false, false);
      return;
    }
    // Sweep invariant — asked immediately before presenting, never at the door.
    // See [_presentBlockedReason]. No `await` sits above this today; the guard
    // is here so that the day one does, the hole does not reopen.
    final blocked = _presentBlockedReason(ad);
    if (blocked != null) {
      SafeLogger.w(_tag, '⏭️ showRewardedInterstitial skipped — $blocked');
      _emitSkip(AdSlotType.rewardedInterstitial, 'show', 'blocked',
          placement: placement);
      onDone(false, false);
      return;
    }
    _lastShownPlacement[AdSlotType.rewardedInterstitial] = placement;
    // Independent review (round 37 verification) — see showInterstitial's
    // identical `delivered` guard above for why this must be set before
    // `onDone` runs, not after.
    var delivered = false;
    try {
      await ad.showRewardedInterstitial(onDone: (result) {
        delivered = true;
        // Round-23 QC (reviewer A, MAJOR) — the impression is counted from
        // `shown`, NOT from `earned`. A user who closes the ad before the
        // reward point still consumed a real, paid, AdMob-billed
        // impression: it has to consume the session/hourly/daily/placement
        // budget and re-arm the 30s fullscreen pacing, or repeated early
        // closes hand out far more fullscreen inventory than the
        // anti-invalid-traffic caps allow.
        //
        // Round-25 QC (reviewer B, MINOR) — this comment used to claim the
        // ordinary rewarded path "has always done this correctly". It had
        // not: the same release moves that path from `earned` to `shown`
        // too. Both were wrong, and a comment that misdescribes its own
        // diff is worse than no comment, because the next reader trusts it.
        if (result.shown) {
          AdSafetyConfig.recordFullscreenAdShown();
          AdSafetyConfig.recordPlacementAdShown(placement); // T92
        }
        if (result.earned) {
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
          // Same round-23 finding: `success` on a *show* event means the ad
          // was displayed, not that the reward was granted. Reporting the
          // reward here made the SDK's own analytics disagree with the
          // impression it billed.
          success: result.shown,
          // T185 — read BEFORE the reload below can overwrite it.
          requestId: ad.rewardedInterstitialSlot.requestId,
        ));
        onDone(result.shown, result.earned);
        unawaited(loadRewardedInterstitialAd());
      });
    } catch (e, st) {
      // Round-37 audit (MAJOR) — see showInterstitial's identical fix above.
      SafeLogger.e(_tag, 'showRewardedInterstitialAd threw: $e\n$st');
      if (!delivered) onDone(false, false);
    }
  }

  /// T181 (codex round-1 fix) — see [canShowInterstitial]'s doc comment:
  /// same reasoning, [placement] defaults to [AdPlacement.unspecified] so
  /// existing callers see unchanged behavior.
  bool canShowRewardedInterstitialAd(
      {AdPlacement placement = AdPlacement.unspecified}) {
    final ad = _adapter;
    if (ad == null) return false;
    if (_isVipMember) return false;
    if (!canRequestAds) return false;
    if (ad.rewardedInterstitialSlot.isShowing) return false;
    // Round-32 audit fix (MAJOR) — this was the one of the three fullscreen
    // canShow* peeks missing this gate (canShowInterstitial/canShowRewardedAd
    // both have it). Without it, a host polling this while another
    // fullscreen flow's non-dismissable AdLoadingDialog is up would see
    // `true` and open the RI disclosure dialog on top of it.
    if (AdLoadingDialog.isShowing) return false;
    // Round-37 audit (MAJOR) — see canShowInterstitial's comment.
    if (AdScreenRouteLogger.isDialogOnTop) return false;
    // T168 — see canShowInterstitial's comment.
    if (customOverlayOnScreen.value) return false;
    // Peek, not canShowFullscreenAd() — see canShowInterstitial's comment.
    final s = AdSafetyConfig.canShowFullscreenAdPeek(
        forType: AdSlotType.rewardedInterstitial,
        minIntervalOverrideMs: _placementMinIntervalOverride(
            placement, AdSlotType.rewardedInterstitial));
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
  /// T181 (codex round-1 fix) — see [canShowInterstitial]'s doc comment:
  /// same reasoning, [placement] defaults to [AdPlacement.unspecified] so
  /// existing callers see unchanged behavior.
  bool canShowRewardedAd({AdPlacement placement = AdPlacement.unspecified}) {
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
    // Round-37 audit (MAJOR) — see canShowInterstitial's comment.
    if (AdScreenRouteLogger.isDialogOnTop) return false;
    // T168 — see canShowInterstitial's comment.
    if (customOverlayOnScreen.value) return false;
    // Peek, not canShowFullscreenAd() — see canShowInterstitial's comment.
    // T147 — this used to pass AdSlotType.rewardedInterstitial (copy-paste
    // from canShowRewardedInterstitialAd() below), so a remote kill switch
    // (T137) disabling one of these two formats gated the WRONG one's
    // button: the real showRewardedAd() call below gates on
    // AdSlotType.rewarded, so this peek must agree with it.
    final s = AdSafetyConfig.canShowFullscreenAdPeek(
        forType: AdSlotType.rewarded,
        minIntervalOverrideMs:
            _placementMinIntervalOverride(placement, AdSlotType.rewarded));
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

    // T155 (codex round 2, P1) — ahead of even the `!isInitialised` guard
    // below: showAppOpenAd(bypassSafety: true) records into bypassAuditTrail
    // unconditionally, before checking either isInitialised or the adapter
    // (see its own call site), so a real bypass can be recorded during the
    // splash window while initialize() is still in flight. Every guard
    // this method has (isInitialised, then adapter-null) would otherwise
    // skip this along with the adapter-dependent work that legitimately
    // needs to wait for those.
    if (state == AppLifecycleState.paused) {
      unawaited(bypassAuditTrail.flush());
    }
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
    // Round-13 QC (round 13), MAJOR — a resume is a free second chance for a
    // gate whose recovery retries all failed (a channel that was wedged while
    // the app was backgrounded is usually not wedged any more). Returns
    // immediately when nothing is owed, which is every ordinary resume.
    _consentGateRecoveryAttempts = 0;
    unawaited(_recoverConsentGate().catchError((Object e) {
      SafeLogger.w(_tag, '_recoverConsentGate threw on resume: $e');
    }));
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
          // T149 — same class of unhandled-zone-error bug as the `else`
          // branch's own fix below: recheckUmpConsentStatus() awaits the
          // same UMP channel calls, and was missing this guard.
          runZonedGuarded(() {
            unawaited(_recheckAbandonedUmpForm());
          }, (e, st) {
            SafeLogger.w(
                _tag,
                '⚠️ UMP backstop abandoned-form recheck threw unhandled: $e '
                '— ignoring, will retry again next backstop tick');
          });
        } else {
          SafeLogger.d(_tag, '🔐 retrying UMP consent on periodic backstop');
          _umpBackstopRetryCount++;
          // Round-39 audit fix (MAJOR) — same class of bug as the init-time
          // auto-UMP flow (see its own comment): requestConsentInfoUpdate is
          // a callback API that throws from a future nobody awaits when the
          // channel is missing/misconfigured — an unhandled zone error no
          // try/catch around the call can see. Sibling call site round 38
          // never patched. Flapping connectivity would otherwise crash the
          // whole app repeatedly.
          runZonedGuarded(() {
            unawaited(_retryUmpConsent());
          }, (e, st) {
            SafeLogger.w(
                _tag,
                '⚠️ UMP backstop retry threw unhandled: $e — ignoring, will '
                'retry again next backstop tick');
          });
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
          // T149 — same class of unhandled-zone-error bug as the `else`
          // branch's own fix below.
          runZonedGuarded(() {
            unawaited(_recheckAbandonedUmpForm());
          }, (e, st) {
            SafeLogger.w(
                _tag,
                '⚠️ UMP reconnect abandoned-form recheck threw unhandled: $e '
                '— ignoring, will retry again next reconnect/backstop tick');
          });
        } else {
          SafeLogger.d(_tag, '🔐 retrying UMP consent after reconnect');
          // Round-39 audit fix (MAJOR) — same class of bug as the init-time
          // auto-UMP flow and the periodic backstop above: an unhandled zone
          // error from requestConsentInfoUpdate no try/catch around this
          // call can see. A user cycling through a weak-signal area (subway,
          // elevator) would otherwise crash the app once per reconnect.
          runZonedGuarded(() {
            unawaited(_retryUmpConsent());
          }, (e, st) {
            SafeLogger.w(
                _tag,
                '⚠️ UMP reconnect retry threw unhandled: $e — ignoring, will '
                'retry again next reconnect');
          });
        }
      }
      // Round-20 QC, MAJOR — a debt whose retries all failed offline had
      // nobody left to pay it: the gate stayed shut for the session even
      // though the network is back and UMP is answering again. This is the
      // one event that says the read which failed can now succeed.
      if (_recoveryStillOwed) {
        unawaited(_recoverConsentGate().catchError((Object e) {
          SafeLogger.w(_tag, '_recoverConsentGate (reconnect) threw: $e');
        }));
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
    // T108 — this scan only ever runs while isConnected (see the guard
    // above), so for any slot opted into AdRetryPolicy.resetOnConnectivityRestored
    // this is exactly the "connectivity restored" moment its cooldown should
    // clear early instead of waiting out a backoff window that may have been
    // computed while offline. No-op for every slot with no policy, or a
    // policy that didn't opt in — matches prior behavior.
    ad.appOpenSlot.clearCooldownOnReconnect();
    ad.interstitialSlot.clearCooldownOnReconnect();
    ad.rewardedSlot.clearCooldownOnReconnect();
    ad.rewardedInterstitialSlot.clearCooldownOnReconnect();
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

  /// Where each fullscreen format was last presented from.
  ///
  /// Round-23 QC (reviewer C, MINOR) — every revenue (paid) event arrived
  /// tagged [AdPlacement.unspecified], because the adapters wire the paid-event
  /// listener when the ad is **loaded** and the placement is only known when it
  /// is **shown**. (App Open was worse than useless: hardcoded to
  /// `AdPlacement.splash`, so a resume impression was reported as splash.) A
  /// host reading `AdManager().events` to find which screen actually earns
  /// money got one undifferentiated bucket, which is the whole point of the
  /// placement API.
  ///
  /// ponytail: written before the show, never cleared WITHIN a session. The
  /// paid event fires on impression, i.e. between the show call and the
  /// dismiss callback — but some mediation adapters report it a beat late,
  /// and a stale entry names the last show of that same format, which is
  /// still the right answer. Clearing would only turn "slightly late" into
  /// "unattributed".
  ///
  /// T160 — this DOES get cleared at a session boundary, in
  /// [_resetGuardState] (see its own comment): a stale placement from a
  /// session that just ended must not get attributed to a revenue event
  /// the NEXT session's adapter reports before its own first show call.
  final Map<AdSlotType, AdPlacement> _lastShownPlacement = {};

  /// Test seam for [_lastShownPlacement] — populating it for real requires
  /// driving a full show() call through a fake adapter; this sets the same
  /// state directly for tests that only care about the attribution/reset
  /// behavior around it (T160).
  @visibleForTesting
  void debugSetLastShownPlacement(AdSlotType type, AdPlacement placement) =>
      _lastShownPlacement[type] = placement;

  // ──────────────────────────────────────────────────────────────────────────
  //  EVENT EMIT — single `_emit()` chokepoint: records to the compliance
  //  event log, then broadcasts on the public `events` stream.
  // ──────────────────────────────────────────────────────────────────────────

  void _emit(AdEvent event) {
    // Revenue is the one event the adapters cannot place themselves — see
    // [_lastShownPlacement]. The show-time placement wins outright, including
    // over App Open's hardcoded `splash`. Inline formats (banner/MREC/native)
    // are untouched: they have no show call to take a placement from.
    if (event is AdRevenueEvent) {
      final shown = _lastShownPlacement[event.type];
      if (shown != null && shown != event.placement) {
        event = AdRevenueEvent(
          providerTag: event.providerTag,
          type: event.type,
          placement: shown,
          valueMicros: event.valueMicros,
          currencyCode: event.currencyCode,
          networkName: event.networkName,
          precision: event.precision,
          mediationWaterfall: event.mediationWaterfall,
        );
      }
      // T126 — creative fatigue guard's only observation point: this is the
      // sole place a mediated network's identity is known SDK-wide.
      AdSafetyConfig.recordNetworkShown(
        event.type,
        event.networkName ??
            (event.mediationWaterfall == null ||
                    event.mediationWaterfall!.isEmpty
                ? null
                : event.mediationWaterfall!.first),
      );
    }
    _eventLog?.recordEvent(event,
        consentCountry: _consentManager?.current.country);
    if (_eventStream.isClosed) return;
    _eventStream.add(event);
  }
}
