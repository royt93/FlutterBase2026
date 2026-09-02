import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../adaptive/adaptive_frequency.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart' show AdSlotType;
import '../utils/ad_preferences.dart';
import '../utils/release_mode.dart';
import '../utils/safe_logger.dart';

/// Result of an ad safety check.
class AdSafetyResult {
  /// Whether the ad is allowed to show.
  final bool canShow;

  /// Human-readable reason (for logging).
  final String reason;

  const AdSafetyResult(this.canShow, this.reason);
}

/// Structured, JSON-able snapshot of [AdSafetyConfig]'s current counters.
///
/// Used by T23 (Compliance Report export) and T24 (policy risk score).
/// Companion to [AdSafetyConfig.getStatus] (the human-readable debug string);
/// this carries the same numbers but as typed fields instead of a formatted
/// string, so callers don't have to parse it.
class AdSafetySnapshot {
  final int fullscreenAdsShownInSession;
  final int maxFullscreenAdsPerSession;
  final int hourlyAdCount;
  final int maxFullscreenAdsPerHour;
  final int dailyAdCount;
  final int maxFullscreenAdsPerDay;
  final double clickThroughRate;
  final double suspiciousCtrThreshold;
  final int clicksLastMinute;
  final int suspiciousViolationCount;
  final bool isSuspended;
  final bool dryRun;

  const AdSafetySnapshot({
    required this.fullscreenAdsShownInSession,
    required this.maxFullscreenAdsPerSession,
    required this.hourlyAdCount,
    required this.maxFullscreenAdsPerHour,
    required this.dailyAdCount,
    required this.maxFullscreenAdsPerDay,
    required this.clickThroughRate,
    required this.suspiciousCtrThreshold,
    required this.clicksLastMinute,
    required this.suspiciousViolationCount,
    required this.isSuspended,
    required this.dryRun,
  });

  Map<String, dynamic> toJson() => {
        'fullscreenAdsShownInSession': fullscreenAdsShownInSession,
        'maxFullscreenAdsPerSession': maxFullscreenAdsPerSession,
        'hourlyAdCount': hourlyAdCount,
        'maxFullscreenAdsPerHour': maxFullscreenAdsPerHour,
        'dailyAdCount': dailyAdCount,
        'maxFullscreenAdsPerDay': maxFullscreenAdsPerDay,
        'clickThroughRate': clickThroughRate,
        'suspiciousCtrThreshold': suspiciousCtrThreshold,
        'clicksLastMinute': clicksLastMinute,
        'suspiciousViolationCount': suspiciousViolationCount,
        'isSuspended': isSuspended,
        'dryRun': dryRun,
      };
}

/// Tunable parameters for [AdSafetyConfig].
///
/// Pass custom values to [AdSafetyConfig.init] to override defaults.
class AdSafetyParams {
  /// Minimum ms between fullscreen ads (default: 60 000 = 60s)
  final int minTimeBetweenFullscreenAds;

  /// Max fullscreen ads per session (default: 6)
  final int maxFullscreenAdsPerSession;

  /// Min ms app must be in background before App Open on resume (default: 5 000)
  final int minTimeAppOpenResume;

  /// Max clicks per minute before suspicious pause (default: 3)
  final int maxClicksPerMinute;

  /// Max fullscreen ads per day — persisted (default: 5)
  final int maxFullscreenAdsPerDay;

  /// Max fullscreen ads per hour (default: 3)
  final int maxFullscreenAdsPerHour;

  /// Min session duration ms before first fullscreen ad (default: 10 000)
  final int minSessionDurationBeforeAd;

  /// CTR threshold above which ads are suspended (default: 0.30 = 30%)
  final double suspiciousCtrThreshold;

  /// Max rapid resumes per minute before skipping App Open (default: 3)
  final int maxRapidResumesPerMinute;

  /// QA mode: log violations but always return `canShow=true`.
  /// **Set to false in production** — bypasses every safety check.
  final bool dryRun;

  /// T26 Phase 1: max ms between a fullscreen ad and a backgrounding for the
  /// `ad_to_background` diagnostic signal to still count as "shortly after"
  /// (default: 300 000 = 5 min). `_lastFullscreenAdTime` itself is never
  /// cleared, so without this window the signal would fire on every
  /// backgrounding for the rest of the session after just one ad.
  final int adToBackgroundSignalWindowMs;

  /// T92 — optional additional daily cap keyed by [AdPlacement], checked in
  /// ADDITION to [maxFullscreenAdsPerDay] at show time — never instead of
  /// it, and never looser (a placement with no entry here has no extra
  /// limit beyond the global one). `null` (default) is fully
  /// backward-compatible: no per-placement limiting at all.
  ///
  /// ```dart
  /// AdSafetyParams(maxPerPlacementAdsPerDay: {AdPlacement.splash: 1})
  /// ```
  ///
  /// **Cannot be used with a `const AdSafetyParams(...)` constructor call**
  /// (unlike every other field here) — [AdPlacement] overrides `==`, and
  /// Dart requires `const` map keys to have primitive identity. Construct a
  /// regular (non-`const`) `AdSafetyParams(...)` instance when setting this,
  /// or use [maxPerPlacementAdsPerDayById] instead if you need a `const`
  /// declaration (e.g. a top-level config constant).
  final Map<AdPlacement, int>? maxPerPlacementAdsPerDay;

  /// T113 — same cap as [maxPerPlacementAdsPerDay], keyed by
  /// [AdPlacement.id] (a plain `String`, which Dart *does* allow as a
  /// `const` map key) instead of by [AdPlacement] instance. Checked in
  /// addition to [maxPerPlacementAdsPerDay] — an entry in either map applies;
  /// having both set for the same placement is redundant, not a conflict.
  ///
  /// ```dart
  /// const AdSafetyParams(maxPerPlacementAdsPerDayById: {'splash': 1})
  /// ```
  final Map<String, int>? maxPerPlacementAdsPerDayById;

  /// T126 — how many times the SAME mediated network may pay out for a given
  /// [AdSlotType] inside [networkFatigueWindowMs] before that type cools down
  /// (default: 4). Catches a mediation waterfall stuck repeatedly filling
  /// from one low-quality network — a symptom of creative fatigue and
  /// abnormal CTR — that the existing per-placement/session/day caps don't
  /// see because they count ads shown, not which network keeps winning.
  final int maxSameNetworkShowsPerWindow;

  /// Rolling window (ms) [maxSameNetworkShowsPerWindow] is measured over
  /// (default: 900 000 = 15 min).
  final int networkFatigueWindowMs;

  const AdSafetyParams({
    this.minTimeBetweenFullscreenAds = 60000,
    this.maxFullscreenAdsPerSession = 6,
    this.minTimeAppOpenResume = 5000,
    this.maxClicksPerMinute = 3,
    this.maxFullscreenAdsPerDay = 5,
    this.maxFullscreenAdsPerHour = 3,
    this.minSessionDurationBeforeAd = 10000,
    this.suspiciousCtrThreshold = 0.30,
    this.maxRapidResumesPerMinute = 3,
    this.dryRun = false,
    this.adToBackgroundSignalWindowMs = 300000,
    this.maxPerPlacementAdsPerDay,
    this.maxPerPlacementAdsPerDayById,
    this.maxSameNetworkShowsPerWindow = 4,
    this.networkFatigueWindowMs = 900000,
  });

  // ─── Presets ──────────────────────────────────────────────────────────────

  /// Production defaults — strict caps. Identical to `const AdSafetyParams()`.
  static const AdSafetyParams production = AdSafetyParams();

  /// Loose limits for development / QA. All caps cranked to 999, throttle 2 s,
  /// session warm-up 0 s, cold-start gate respected (still blocks the very
  /// first resume). Use this preset when you need to iterate fast on ad UI
  /// without hitting daily/hourly walls.
  ///
  /// ```dart
  /// safety: AdSafetyParams.debug
  /// ```
  static const AdSafetyParams debug = AdSafetyParams(
    minTimeBetweenFullscreenAds: 2000, // 2 s
    maxFullscreenAdsPerSession: 999,
    maxFullscreenAdsPerHour: 999,
    maxFullscreenAdsPerDay: 999,
    minSessionDurationBeforeAd: 0,
    minTimeAppOpenResume: 0,
    maxClicksPerMinute: 999,
    suspiciousCtrThreshold: 1.0,
    maxRapidResumesPerMinute: 999,
    dryRun: false,
    maxSameNetworkShowsPerWindow: 999,
  );

  /// Auto-pick: [debug] in `kDebugMode` builds, [production] in release.
  /// This is what `AdConfig` defaults to — the host app can still override
  /// via `AdConfig.safety: AdSafetyParams.production` (force strict in dev)
  /// or `AdSafetyParams.debug` (force loose in release; not recommended).
  static const AdSafetyParams auto = kDebugMode ? debug : production;

  /// Returns a copy of this with the given fields replaced. Use to override
  /// just the knobs you care about while keeping the rest:
  ///
  /// ```dart
  /// safety: AdSafetyParams.production.copyWith(maxFullscreenAdsPerDay: 10)
  /// ```
  AdSafetyParams copyWith({
    int? minTimeBetweenFullscreenAds,
    int? maxFullscreenAdsPerSession,
    int? minTimeAppOpenResume,
    int? maxClicksPerMinute,
    int? maxFullscreenAdsPerDay,
    int? maxFullscreenAdsPerHour,
    int? minSessionDurationBeforeAd,
    double? suspiciousCtrThreshold,
    int? maxRapidResumesPerMinute,
    bool? dryRun,
    int? adToBackgroundSignalWindowMs,
    Map<AdPlacement, int>? maxPerPlacementAdsPerDay,
    Map<String, int>? maxPerPlacementAdsPerDayById,
    int? maxSameNetworkShowsPerWindow,
    int? networkFatigueWindowMs,
  }) {
    return AdSafetyParams(
      minTimeBetweenFullscreenAds:
          minTimeBetweenFullscreenAds ?? this.minTimeBetweenFullscreenAds,
      maxFullscreenAdsPerSession:
          maxFullscreenAdsPerSession ?? this.maxFullscreenAdsPerSession,
      minTimeAppOpenResume: minTimeAppOpenResume ?? this.minTimeAppOpenResume,
      maxClicksPerMinute: maxClicksPerMinute ?? this.maxClicksPerMinute,
      maxFullscreenAdsPerDay:
          maxFullscreenAdsPerDay ?? this.maxFullscreenAdsPerDay,
      maxFullscreenAdsPerHour:
          maxFullscreenAdsPerHour ?? this.maxFullscreenAdsPerHour,
      minSessionDurationBeforeAd:
          minSessionDurationBeforeAd ?? this.minSessionDurationBeforeAd,
      suspiciousCtrThreshold:
          suspiciousCtrThreshold ?? this.suspiciousCtrThreshold,
      maxRapidResumesPerMinute:
          maxRapidResumesPerMinute ?? this.maxRapidResumesPerMinute,
      dryRun: dryRun ?? this.dryRun,
      adToBackgroundSignalWindowMs:
          adToBackgroundSignalWindowMs ?? this.adToBackgroundSignalWindowMs,
      maxPerPlacementAdsPerDay:
          maxPerPlacementAdsPerDay ?? this.maxPerPlacementAdsPerDay,
      maxPerPlacementAdsPerDayById:
          maxPerPlacementAdsPerDayById ?? this.maxPerPlacementAdsPerDayById,
      maxSameNetworkShowsPerWindow:
          maxSameNetworkShowsPerWindow ?? this.maxSameNetworkShowsPerWindow,
      networkFatigueWindowMs:
          networkFatigueWindowMs ?? this.networkFatigueWindowMs,
    );
  }

  @override
  String toString() => 'AdSafetyParams('
      'between=${minTimeBetweenFullscreenAds}ms, '
      'session=$maxFullscreenAdsPerSession, '
      'hour=$maxFullscreenAdsPerHour, '
      'day=$maxFullscreenAdsPerDay, '
      'warmup=${minSessionDurationBeforeAd}ms, '
      'resume=${minTimeAppOpenResume}ms, '
      'clicks/min=$maxClicksPerMinute, '
      'ctr=$suspiciousCtrThreshold, '
      'rapidResume=$maxRapidResumesPerMinute, '
      'dryRun=$dryRun)';
}

/// Ad safety manager — 12 anti-fraud protections.
///
/// Implements throttle, session/hourly/daily caps, CTR monitoring,
/// progressive cooldown, rapid-resume detection.
class AdSafetyConfig {
  static const String _tag = 'AdSafety';

  static AdSafetyParams _params = const AdSafetyParams();

  // ════════════════ CONSTANTS ════════════════
  static const int _baseSuspiciousPause = 30 * 60 * 1000; // 30 min
  static const int _maxSuspiciousPause = 24 * 60 * 60 * 1000; // 24 h

  // ════════════════ STATE ════════════════
  static int _lastFullscreenAdTime = 0;
  static int _fullscreenAdsShownInSession = 0;
  static int _lastBackgroundTime = 0;
  // T26 Phase 1: one-shot guard so `background_to_resume` fires at most once
  // per backgrounding — `_lastBackgroundTime` itself can't be cleared after
  // recording since the unbounded `minTimeAppOpenResume` gate below also
  // reads it, so a `resumed` firing twice without an intervening `paused`
  // (permission dialogs, notification-shade dips) would otherwise re-emit
  // stale signal data forever.
  static bool _backgroundToResumeSignalPending = false;
  // T66 — separate one-shot flag gating the actual "resume too fast" show
  // decision (not just the diagnostic signal above). Consumed by the first
  // resume check after a real `paused`; a second `resumed` with no new
  // `paused` in between (Android's `resumed → inactive → resumed` dip for a
  // permission dialog/notification shade) finds this already consumed and
  // is blocked outright, instead of reusing `_lastBackgroundTime` — which
  // would otherwise look like a long-ago backgrounding and pass the gate.
  static bool _pendingResumeGate = false;
  static bool _isColdStart = true;
  static final List<int> _clickTimestamps = [];
  static int _suspiciousPauseUntil = 0;

  // T126 — rolling exposure per (AdSlotType, network), keyed
  // "${type.name}|$network". Only ever holds entries for a network that was
  // actually reported (see [recordNetworkShown]'s fail-open null check), so
  // an empty/absent key naturally means "no signal, don't block".
  static final Map<String, List<int>> _networkShowTimestamps = {};

  /// Whether the invalid-traffic cooldown is currently holding ads back.
  ///
  /// Exposed separately from [canShowFullscreenAd] because the splash App Open
  /// shows with `bypassSafety: true`, and that flag is meant to skip the
  /// *frequency* limits (daily cap, 30s throttle, per-placement cap) — not the
  /// anti-invalid-traffic pause, which exists to protect the publisher's AdMob
  /// account rather than to pace the user. Round-6 audit found the pause was
  /// being skipped along with the caps at exactly the surface that shows most
  /// often, so a device already flagged for click fraud kept being served on
  /// every app launch.
  ///
  /// Read-only and side-effect free: unlike [canShowFullscreenAd] this records
  /// no violation, so it is safe on a bypass path.
  static bool get isInvalidTrafficPauseActive =>
      DateTime.now().millisecondsSinceEpoch < _suspiciousPauseUntil;
  static int _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
  static final List<int> _hourlyAdTimestamps = [];
  static final List<int> _resumeTimestamps = [];
  static int _totalImpressions = 0;
  static int _totalClicks = 0;

  /// Round-31 audit fix (MAJOR) — `_totalImpressions` snapshot at the last
  /// CTR-anomaly trigger. A blocked show attempt never adds an impression,
  /// so without this, the very next genuine show attempt after a pause
  /// window elapses re-evaluates the exact same stale ratio and
  /// re-triggers immediately, escalating the pause exponentially (30m → 1h
  /// → 2h → ...) from a single ambiguous burst at the start of a session.
  /// Requiring 5 NEW impressions since the last trigger before re-checking
  /// gives the ratio a chance to actually move — while, unlike resetting
  /// `_totalImpressions`/`_totalClicks` outright, leaving the running CTR
  /// visible to [_computeRiskScore]'s `ctrComponent` untouched.
  static int _ctrPauseTriggeredAtImpressionCount = -5;
  static int _suspiciousViolationCount = 0;
  static int _lastViolationTimestamp = 0;
  // T24 re-audit fix: violations already reflected by another additive risk
  // score component (currently CTR anomalies, which feed `ctrComponent`
  // directly off the same `ctr` value) must not also inflate
  // `violationComponent` — that was double-penalising one signal under two
  // labels. `_suspiciousViolationCount` above still counts every violation
  // for the progressive-cooldown escalation, unchanged.
  static int _scoreableViolationCount = 0;
  static AdPreferences? _prefs;

  /// Sink for [AdAnomalyEvent] (T25), set by [AdManager] at init to avoid a
  /// reverse import (mirrors the [_prefs] injection pattern).
  static void Function(AdAnomalyEvent)? _anomalySink;

  /// Wire an [AdAnomalyEvent] sink — call once from `AdManager.initialize()`.
  static void setAnomalySink(void Function(AdAnomalyEvent) sink) {
    _anomalySink = sink;
  }

  /// 0-100 real-time policy risk score (T24) — blends CTR anomaly, decayed
  /// suspicious-violation history and resume-spam into one reactive number.
  /// Refreshed after every event that can move the score; watch this instead
  /// of polling [getPolicyRiskScore]. Not shown to end-users — a dev/partner
  /// signal only.
  static final ValueNotifier<int> policyRiskScore = ValueNotifier<int>(0);

  /// Initialize with optional custom [params].
  /// R12-A: dryRun bypasses every real safety cap (session/hourly/daily/
  /// throttle) — a `dryRun: true` left in by mistake for a release build
  /// would silently disable ad-safety enforcement for every user. `assert`
  /// is stripped in release mode (the exact mode this must catch), so this
  /// forces it off at runtime instead of just asserting. [isRelease]
  /// defaults to [kReleaseMode] and is only overridden by tests, since
  /// `kReleaseMode` itself is always false under `flutter test`.
  /// R12-A follow-up: this method and [init] are both re-exported by the
  /// package barrel, so an external caller could otherwise pass
  /// `isRelease: false` straight into a real release build to defeat this
  /// guard. [isActuallyRelease] closes that: a caller-supplied [isRelease]
  /// can only make the check MORE strict (simulate release while testing),
  /// never less — a genuine release build always forces the guard on
  /// regardless of what's passed in.
  @visibleForTesting
  static AdSafetyParams applyDryRunReleaseGuard(
    AdSafetyParams params, {
    bool isRelease = kReleaseMode,
  }) {
    if (params.dryRun && isActuallyRelease(isRelease)) {
      // critical (not `e`): this must still reach AdConfig.onLog even if
      // the host silenced logging with logLevel: AdLogLevel.none.
      SafeLogger.critical(_tag,
          '🚨 AdSafetyParams.dryRun=true in a release build — forcing dryRun=false to keep ad-safety caps enforced');
      return params.copyWith(dryRun: false);
    }
    return params;
  }

  // `isRelease` isn't `@visibleForTesting` here for the same barrel-export
  // reason covered in [applyDryRunReleaseGuard]'s doc comment above —
  // safety comes from `isActuallyRelease`, not the annotation.
  static Future<void> init(
    AdPreferences prefs, {
    AdSafetyParams params = const AdSafetyParams(),
    bool isRelease = kReleaseMode,
  }) async {
    _prefs = prefs;
    params = applyDryRunReleaseGuard(params, isRelease: isRelease);
    _params = params;
    _suspiciousViolationCount = prefs.getSuspiciousCount();
    _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
    SafeLogger.d(
      _tag,
      '🔄 init, dailyAds=${prefs.getDailyAdCount()}/${params.maxFullscreenAdsPerDay}, '
      'suspiciousCount=$_suspiciousViolationCount',
    );
    _refreshRiskScore();
  }

  /// T111 — swap in a new [params] WITHOUT the rest of [init]'s cold-start
  /// bookkeeping (`_suspiciousViolationCount`/`_sessionStartTime` re-read
  /// from `prefs`). A live refresh must not reset a session already in
  /// progress — only [init] (a real cold start) should do that.
  static void updateParams(AdSafetyParams params,
      {bool isRelease = kReleaseMode}) {
    _params = applyDryRunReleaseGuard(params, isRelease: isRelease);
  }

  /// Check whether a fullscreen ad (inter/rewarded/app-open) can be shown.
  /// Honours `params.dryRun` — if set, blocks are logged but always return ok.
  ///
  /// **Has a side effect**: a CTR-anomaly detection here re-arms the
  /// suspicious-pause window (escalating on every call). Call this ONLY at
  /// the moment of a genuine show attempt — for a UI-facing "should I enable
  /// my ad button" query, use [canShowFullscreenAdPeek] instead. Polling
  /// THIS one for that purpose was a real bug (2026-08-16 audit): since a
  /// blocked ad never adds an impression, CTR can never recover on its own,
  /// so every poll after each pause window naturally expires would
  /// re-trigger and escalate the SAME violation forever, even with zero new
  /// clicks — a permanent, ever-worsening lockout from nothing but reading
  /// state.
  static AdSafetyResult canShowFullscreenAd() {
    final result = _canShowFullscreenAdStrict(recordViolation: true);
    if (!result.canShow && _params.dryRun) {
      SafeLogger.w(
          _tag, '⚠️ dryRun: would have blocked (${result.reason}) — allowing');
      return AdSafetyResult(true, 'dryRun-bypass(${result.reason})');
    }
    return result;
  }

  /// Same checks as [canShowFullscreenAd], but **no side effects** — safe to
  /// poll repeatedly (e.g. to drive a "Watch Ad" button's enabled state)
  /// without re-arming/escalating the CTR-anomaly suspicious-pause window.
  /// Use this for any "should I show/enable" query; reserve
  /// [canShowFullscreenAd] for an actual show attempt.
  static AdSafetyResult canShowFullscreenAdPeek() {
    final result = _canShowFullscreenAdStrict(recordViolation: false);
    if (!result.canShow && _params.dryRun) {
      return AdSafetyResult(true, 'dryRun-bypass(${result.reason})');
    }
    return result;
  }

  /// Pure read-only check: has the daily fullscreen-ad cap already been hit?
  /// Unlike [canShowFullscreenAd], has no side effects (no CTR-anomaly
  /// bookkeeping) — safe to call before *loading* an ad, not just showing one,
  /// so preload doesn't burn network requests that can never convert.
  static bool dailyCapReached() =>
      (_prefs?.getDailyAdCount() ?? 0) >= _params.maxFullscreenAdsPerDay;

  /// T92 — checked in ADDITION to [dailyCapReached]/[canShowFullscreenAd] at
  /// show time, never in place of them. `false` (never blocks) if
  /// [AdSafetyParams.maxPerPlacementAdsPerDay] has no entry for [placement] —
  /// the global cap alone still applies as always.
  static bool placementDailyCapReached(AdPlacement placement) {
    final maxPerDay = _params.maxPerPlacementAdsPerDay?[placement] ??
        _params.maxPerPlacementAdsPerDayById?[placement.id];
    if (maxPerDay == null) return false;
    final counts = _prefs?.getPlacementDailyCounts() ?? const {};
    return (counts[placement.id] ?? 0) >= maxPerDay;
  }

  /// Records a shown ad against [placement]'s per-placement counter. Safe to
  /// call unconditionally — a placement with no configured cap just
  /// accumulates a count nothing ever reads.
  static void recordPlacementAdShown(AdPlacement placement) {
    unawaited(_prefs?.incrementPlacementDailyCount(placement.id));
  }

  /// T126 — records that [network] just paid out for [type], for the
  /// creative-fatigue window check in [isNetworkFatigued]. Fail-open by
  /// design: a `null`/empty [network] (AdMob doesn't always report one — see
  /// `AdRevenueEvent.networkName`'s doc) is silently dropped rather than
  /// tracked, so missing metadata can never itself trigger a cooldown.
  static void recordNetworkShown(AdSlotType type, String? network) {
    if (network == null || network.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '${type.name}|$network';
    final list = _networkShowTimestamps.putIfAbsent(key, () => []);
    list.add(now);
    list.removeWhere((t) => now - t > _params.networkFatigueWindowMs);
  }

  /// T126 — has any single network shown for [type] recently enough, often
  /// enough (within [AdSafetyParams.networkFatigueWindowMs]) to count as
  /// creative fatigue? `false` whenever there is no exposure history for
  /// [type] at all — this only ever cools down a slot type it has actual
  /// same-network repetition data for, never a format nothing has reported
  /// network metadata for yet.
  static bool isNetworkFatigued(AdSlotType type) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final prefix = '${type.name}|';
    for (final entry in _networkShowTimestamps.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      entry.value.removeWhere((t) => now - t > _params.networkFatigueWindowMs);
      if (entry.value.length >= _params.maxSameNetworkShowsPerWindow) {
        return true;
      }
    }
    return false;
  }

  static AdSafetyResult _canShowFullscreenAdStrict(
      {required bool recordViolation}) {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (now < _suspiciousPauseUntil) {
      final remainingMs = _suspiciousPauseUntil - now;
      SafeLogger.d(_tag, '🛡️ Ads paused, remaining=${_fmtWait(remainingMs)}');
      return AdSafetyResult(
          false, 'Suspended: ${_fmtWait(remainingMs)} remaining');
    }

    final sessionDuration = now - _sessionStartTime;
    if (sessionDuration < _params.minSessionDurationBeforeAd) {
      final waitMs = _params.minSessionDurationBeforeAd - sessionDuration;
      SafeLogger.d(_tag,
          '🛡️ Session too young (${_fmtWait(sessionDuration)}), wait ${_fmtWait(waitMs)}');
      return AdSafetyResult(
          false, 'Session too young: wait ${_fmtWait(waitMs)}');
    }

    if (_fullscreenAdsShownInSession >= _params.maxFullscreenAdsPerSession) {
      SafeLogger.d(_tag,
          '🛡️ Session limit: $_fullscreenAdsShownInSession/${_params.maxFullscreenAdsPerSession}');
      return AdSafetyResult(
          false, 'Session limit: $_fullscreenAdsShownInSession ads');
    }

    _hourlyAdTimestamps.removeWhere((t) => now - t > 3600000);
    if (_hourlyAdTimestamps.length >= _params.maxFullscreenAdsPerHour) {
      SafeLogger.d(_tag,
          '🛡️ Hourly cap: ${_hourlyAdTimestamps.length}/${_params.maxFullscreenAdsPerHour}');
      return AdSafetyResult(
          false, 'Hourly cap: ${_hourlyAdTimestamps.length} ads');
    }

    final dailyCount = _prefs?.getDailyAdCount() ?? 0;
    if (dailyCount >= _params.maxFullscreenAdsPerDay) {
      SafeLogger.d(_tag,
          '🛡️ Daily limit: $dailyCount/${_params.maxFullscreenAdsPerDay}');
      return AdSafetyResult(false, 'Daily limit: $dailyCount ads');
    }

    if (_lastFullscreenAdTime > 0) {
      final elapsed = now - _lastFullscreenAdTime;
      if (elapsed < _params.minTimeBetweenFullscreenAds) {
        final waitMs = _params.minTimeBetweenFullscreenAds - elapsed;
        SafeLogger.d(_tag,
            '🛡️ Throttle: last fullscreen ${_fmtWait(elapsed)} ago, wait ${_fmtWait(waitMs)}');
        return AdSafetyResult(false, 'Throttle: wait ${_fmtWait(waitMs)}');
      }
    }

    // Round-31 audit fix — gate SKIPPED (not just "don't re-trigger") until
    // 5 NEW impressions land since the last trigger. A blocked show attempt
    // never adds an impression, so if this kept actively blocking on the
    // same stale ratio, no new impression could ever happen and the ratio
    // could never move — a permanent deadlock, worse than the pre-fix
    // ever-escalating pause. Skipping the gate lets the very next genuine
    // attempt through so the ratio actually has a chance to dilute; the
    // running CTR itself is untouched, so [_computeRiskScore]'s
    // `ctrComponent` still reflects the true cumulative ratio throughout.
    if (_totalImpressions >= 5 &&
        _totalImpressions - _ctrPauseTriggeredAtImpressionCount >= 5) {
      final ctr = _totalClicks.toDouble() / _totalImpressions.toDouble();
      if (ctr > _params.suspiciousCtrThreshold) {
        if (recordViolation) {
          _ctrPauseTriggeredAtImpressionCount = _totalImpressions;
          _triggerSuspiciousPause(
            'CTR anomaly: ${(ctr * 100).toInt()}% '
            '(threshold: ${(_params.suspiciousCtrThreshold * 100).toInt()}%)',
            // Same `ctr` value already feeds `ctrComponent` directly below —
            // don't also inflate `violationComponent` for it.
            countsTowardRiskScore: false,
          );
        }
        return AdSafetyResult(false, 'CTR too high: ${(ctr * 100).toInt()}%');
      }
    }

    return const AdSafetyResult(true, 'OK');
  }

  /// Check whether App Open can be shown on app resume. Returns a structured
  /// result so callers can log the specific reason + remaining wait time.
  ///
  /// Honours `params.dryRun` — if set, blocks are logged but always returns
  /// `canShow=true` (with the original block reason annotated).
  static AdSafetyResult canShowAppOpenOnResume() {
    // T26 Phase 1: proxy signal (b) — gap between the last backgrounding and
    // this resume. Diagnostic only, recorded before any gate so it always
    // fires regardless of the strict-check outcome. Gated on the one-shot
    // flag (not just `_lastBackgroundTime > 0`) so a `resumed` firing twice
    // without an intervening `paused` doesn't re-emit the same stale gap.
    if (_backgroundToResumeSignalPending && _lastBackgroundTime > 0) {
      _backgroundToResumeSignalPending = false;
      final now = DateTime.now().millisecondsSinceEpoch;
      AdaptiveFrequencySignals.record(
        'background_to_resume',
        now,
        now - _lastBackgroundTime,
      );
    }
    final result = _canShowAppOpenOnResumeStrict();
    if (!result.canShow && _params.dryRun) {
      SafeLogger.w(_tag,
          '⚠️ dryRun: would have blocked App Open on resume — allowing (${result.reason})');
      return AdSafetyResult(true, 'dryRun-bypass(${result.reason})');
    }
    return result;
  }

  static AdSafetyResult _canShowAppOpenOnResumeStrict() {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Fix #45: Respect minTimeBetweenFullscreenAds — prevents showing
    // App Open immediately after an interstitial/rewarded dismissal.
    if (_lastFullscreenAdTime > 0) {
      final elapsed = now - _lastFullscreenAdTime;
      if (elapsed < _params.minTimeBetweenFullscreenAds) {
        final waitMs = _params.minTimeBetweenFullscreenAds - elapsed;
        final reason =
            'fullscreen throttle (last fullscreen ${elapsed}ms ago, wait ${_fmtWait(waitMs)})';
        SafeLogger.d(_tag, '🛡️ App Open on resume blocked: $reason');
        return AdSafetyResult(false, reason);
      }
    }

    if (_isColdStart) {
      // Don't consume cold start flag yet — only consume when we actually
      // return true (i.e., ad is allowed). This way, if resume is blocked
      // by other checks, cold start protection isn't wasted.
      SafeLogger.d(_tag,
          '🛡️ Skipping App Open on cold start (one-shot, will allow next resume)');
      _isColdStart =
          false; // consumed regardless — first resume is always skipped
      return const AdSafetyResult(
          false, 'cold start (one-shot — next resume will pass)');
    }

    if (_lastBackgroundTime > 0) {
      if (!_pendingResumeGate) {
        // T66 — a `resumed` fired with no new `paused` since the last time
        // we evaluated one (e.g. a permission dialog or notification-shade
        // drag on Android, which never sends `paused`). There is no real
        // backgrounding to measure for this resume, so block outright
        // instead of reusing the previous (now stale) _lastBackgroundTime.
        const reason =
            'resume with no new background since the last check (spurious lifecycle event)';
        SafeLogger.d(_tag, '🛡️ App Open on resume blocked: $reason');
        return const AdSafetyResult(false, reason);
      }
      _pendingResumeGate = false;
      final timeInBackground = now - _lastBackgroundTime;
      if (timeInBackground < _params.minTimeAppOpenResume) {
        final waitMs = _params.minTimeAppOpenResume - timeInBackground;
        final reason =
            'resume too fast (background ${timeInBackground}ms < min ${_params.minTimeAppOpenResume}ms, wait ${_fmtWait(waitMs)})';
        SafeLogger.d(_tag, '🛡️ App Open on resume blocked: $reason');
        return AdSafetyResult(false, reason);
      }
    }

    _resumeTimestamps.add(now);
    _resumeTimestamps.removeWhere((t) => now - t > 60000);
    _refreshRiskScore();
    if (_resumeTimestamps.length > _params.maxRapidResumesPerMinute) {
      final reason =
          'rapid resume (${_resumeTimestamps.length} resumes/min > cap ${_params.maxRapidResumesPerMinute}, wait up to 60s)';
      SafeLogger.d(_tag, '🛡️ App Open on resume blocked: $reason');
      // Round-29 audit (MAJOR) — this used to `.clear()` the whole rolling
      // window on trip, which wiped its own evidence: the very next resume
      // saw an empty list and passed, so a burst only ever lost its
      // (N+1)th attempt before resetting to zero — an attacker (or a
      // flapping OS lifecycle) got through in batches of N indefinitely
      // instead of being capped at N per any rolling 60s window as this
      // reason string and `removeWhere` above both already promise. Leave
      // the timestamp in place and let the natural 60s sliding-window
      // expiry (line above) be the only thing that un-blocks future calls,
      // matching every other rolling-window check in this file.
      return AdSafetyResult(false, reason);
    }

    return const AdSafetyResult(true, 'ok');
  }

  /// Pretty-print a wait duration as "Xs" when ≥ 1 s, "Yms" otherwise.
  /// Avoids the "wait 0s" bug where sub-second waits truncated to 0.
  static String _fmtWait(int ms) {
    if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${ms}ms';
  }

  /// Record that a fullscreen ad was shown.
  static void recordFullscreenAdShown() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastFullscreenAdTime = now;
    _fullscreenAdsShownInSession++;
    _totalImpressions++;
    _hourlyAdTimestamps.add(now);
    _prefs?.incrementDailyAdCount();

    final daily = _prefs?.getDailyAdCount() ?? _fullscreenAdsShownInSession;
    SafeLogger.d(
      _tag,
      '📊 Ad SHOWN | session=$_fullscreenAdsShownInSession/${_params.maxFullscreenAdsPerSession} '
      '| hourly=${_hourlyAdTimestamps.length}/${_params.maxFullscreenAdsPerHour} '
      '| daily=$daily/${_params.maxFullscreenAdsPerDay} '
      '| impressions=$_totalImpressions',
    );
    _refreshRiskScore();
  }

  /// Record a banner ad impression (initial load only, not refreshes).
  /// Counts towards total impressions for CTR calculation.
  static void recordBannerImpression() {
    _totalImpressions++;
    SafeLogger.d(
        _tag, '📊 Banner impression | totalImpressions=$_totalImpressions');
    _refreshRiskScore();
  }

  /// Record that the user clicked an ad.
  /// When an ad was last clicked, and whether the app then went to background
  /// while that click was still fresh.
  ///
  /// M1 (round-6 audit) — clicks were recorded at 14 call sites but only ever
  /// reached the click-spam window and the CTR counter, so nothing could answer
  /// "did the user leave because they tapped an ad?". That is the case Google's
  /// App Open policy names: tap a banner, the browser or store opens, come
  /// back, and an App Open ad is waiting.
  ///
  /// A time window on the RESUME side would not work — a user can spend five
  /// seconds or five minutes on the landing page, so any window is either
  /// useless or starves legitimate App Opens. What is bounded is the other
  /// half: the browser opens essentially immediately after the tap, so a
  /// backgrounding within [_clickToBackgroundWindowMs] of a click is
  /// attributable to it. The verdict is latched at that moment and read once on
  /// the next resume, which makes the time away irrelevant.
  static int _lastAdClickAt = 0;
  static bool _backgroundedFromAdClick = false;

  /// How soon after a click a backgrounding counts as caused by it. Deliberately
  /// tight — this is tap-to-browser latency, not user dwell time. Not reusing
  /// [AdSafetyParams.adToBackgroundSignalWindowMs] (5 min): that one is a
  /// diagnostic signal for fullscreen ads, and at five minutes it would flag
  /// almost any backgrounding that happened to follow a click.
  static const int _clickToBackgroundWindowMs = 5000;

  /// True when the last backgrounding followed an ad click closely enough to be
  /// caused by it. Reading it clears the latch, so it gates exactly one resume.
  static bool consumeBackgroundedFromAdClick() {
    final v = _backgroundedFromAdClick;
    _backgroundedFromAdClick = false;
    return v;
  }

  static void recordAdClick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastAdClickAt = now;
    _totalClicks++;
    _clickTimestamps.add(now);
    _clickTimestamps.removeWhere((t) => now - t > 60000);

    final ctr = _totalImpressions > 0
        ? (_totalClicks.toDouble() / _totalImpressions * 100).toInt()
        : 0;
    SafeLogger.d(
      _tag,
      '📊 Click | clicks/min=${_clickTimestamps.length}/${_params.maxClicksPerMinute} '
      '| CTR=$ctr% | total=$_totalClicks/$_totalImpressions',
    );

    if (_clickTimestamps.length > _params.maxClicksPerMinute) {
      _triggerSuspiciousPause(
          'Click spam: ${_clickTimestamps.length} clicks/min');
      _clickTimestamps.clear();
    }
    _refreshRiskScore();
  }

  /// Record that the app went to background.
  static void recordAppWentBackground() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastBackgroundTime = now;
    _backgroundToResumeSignalPending = true;
    _pendingResumeGate = true;
    SafeLogger.d(_tag, '📊 App went to background');
    // M1 — latch the ad-click attribution here, while the gap is still
    // meaningful. See [_lastAdClickAt].
    if (_lastAdClickAt > 0 && now - _lastAdClickAt <= _clickToBackgroundWindowMs) {
      _backgroundedFromAdClick = true;
      SafeLogger.d(_tag,
          '📊 backgrounding attributed to an ad click ${now - _lastAdClickAt}ms ago');
      // Round-6 QC — spend the click here. Leaving it set let a SECOND
      // backgrounding still inside the 5s window re-latch off the same click:
      // click at t=0, leave at t=1s, come back at t=2s (latch consumed), leave
      // again at t=3s, and that unrelated trip was suppressed too. A click
      // explains one departure, not every departure for the next five seconds.
      _lastAdClickAt = 0;
    }
    // T26 Phase 1: proxy signal (a) — did this backgrounding happen shortly
    // after a fullscreen ad? Diagnostic only, no cap is affected.
    // `_lastFullscreenAdTime` is never cleared once set (it's also read by
    // the unbounded throttle checks above), so this needs its own freshness
    // window — otherwise it fires on every backgrounding for the rest of the
    // session after just one ad.
    if (_lastFullscreenAdTime > 0) {
      final gap = now - _lastFullscreenAdTime;
      if (gap <= _params.adToBackgroundSignalWindowMs) {
        AdaptiveFrequencySignals.record('ad_to_background', now, gap);
      }
    }
  }

  static int getSessionAdCount() => _fullscreenAdsShownInSession;

  /// Clears the per-session pacing counters — nothing else.
  ///
  /// This is the reset a host app may call (a debug screen, a "start over"
  /// action). It deliberately leaves the invalid-traffic history alone:
  /// violation count, the active pause and its persisted counter all survive.
  ///
  /// M2 (round-6 audit) — before this split there was only [resetSession],
  /// which clears the fraud history too, and it was reachable from any
  /// consuming app through the exported [AdSafetyConfig]. One call defeated the
  /// whole progressive cooldown (30 min → 24 h), and the example shipped a
  /// button wired to it labelled "Reset session counters", which is exactly
  /// what a host would assume it did. That cooldown protects the publisher's
  /// AdMob account rather than pacing the user, so it is not a host's to clear.
  static void resetSessionCounters() {
    _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
    _fullscreenAdsShownInSession = 0;
    _hourlyAdTimestamps.clear();
    _resumeTimestamps.clear();
    _totalImpressions = 0;
    _totalClicks = 0;
    _ctrPauseTriggeredAtImpressionCount = -5;
    _clickTimestamps.clear();
    _networkShowTimestamps.clear();
    _lastAdClickAt = 0;
    _backgroundedFromAdClick = false;
    SafeLogger.d(_tag, '🔄 Session counters reset (fraud history preserved)');
    _refreshRiskScore();
  }

  /// Full session reset, **including** the invalid-traffic history.
  ///
  /// Internal to the SDK's own destroy/re-init flow (via [resetForReinit]) and
  /// to tests. T24's reasoning is preserved deliberately: a reset that reported
  /// `suspended=true` with 0 violations was itself the bug, so once this runs
  /// it clears the violation counters, the derived pause and the persisted
  /// count together. Hosts should call [resetSessionCounters] instead — see M2
  /// there for why.
  @visibleForTesting
  static void resetSession() {
    _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
    _fullscreenAdsShownInSession = 0;
    _hourlyAdTimestamps.clear();
    _resumeTimestamps.clear();
    _totalImpressions = 0;
    _totalClicks = 0;
    _ctrPauseTriggeredAtImpressionCount = -5;
    // T24 re-audit fix: the click-spam sliding window is per-session state
    // too — leaving it here meant clicks from before a reset still counted
    // toward the spam threshold afterward.
    _clickTimestamps.clear();
    _networkShowTimestamps.clear();
    // M1 — same reasoning as the click-spam window directly above: a click
    // from before the reset must not attribute a later backgrounding. Leaving
    // these set made the very first test after an ad-click test skip App Open
    // for a click that belonged to the previous session.
    _lastAdClickAt = 0;
    _backgroundedFromAdClick = false;
    // T24 re-audit fix: violation history is per-session, not a lifetime
    // ban — leaving it set here meant only the rarely-triggered
    // resetForReinit() ever cleared it, so a session reset (Reset button /
    // test isolation) looked full but silently left old violations alive.
    _suspiciousViolationCount = 0;
    _scoreableViolationCount = 0;
    _lastViolationTimestamp = 0;
    // The active pause is derived from the violation count above — leaving
    // it set here meant a reset session could still report suspended=true
    // with 0 violations.
    _suspiciousPauseUntil = 0;
    // Round-7 audit, MAJOR — the PERSISTED counter deliberately survives.
    // This method runs from `resetForReinit()`, which is public, exported, and
    // runs on every `AdManager().destroy()`; a host that calls
    // destroy() + initialize() (provider switch, logout, a settings screen
    // that re-inits) used to wipe `setSuspiciousCount(0)` with it and so reset
    // the progressive cooldown escalation (30 min → 24 h) to zero every time.
    // M2 (round 6) closed that door on `resetSessionCounters()` and left this
    // one open. Clearing the in-memory count and pause here is fine — a plain
    // process restart already does exactly that, `_suspiciousPauseUntil` has
    // never been persisted — but the escalation counter is the part a restart
    // keeps, and it is what protects the publisher's AdMob account from an
    // invalid-traffic strike. `initialize()` reads it straight back.
    SafeLogger.d(
        _tag, '🔄 Session reset (persisted invalid-traffic count preserved)');
    _refreshRiskScore();
  }

  /// Full reset for destroy() + re-initialize() flows.
  /// Unlike [resetSession], this also resets [_isColdStart].
  static void resetForReinit() {
    resetSession();
    _isColdStart = true;
    _lastFullscreenAdTime = 0;
    _lastBackgroundTime = 0;
    _backgroundToResumeSignalPending = false;
    _pendingResumeGate = false;
    AdaptiveFrequencySignals.reset();
    SafeLogger.d(_tag, '🔄 Full reinit reset (coldStart restored)');
    _refreshRiskScore();
  }

  static String getStatus() {
    final ctr = _totalImpressions > 0
        ? (_totalClicks.toDouble() / _totalImpressions * 100).toInt()
        : 0;
    final daily = _prefs?.getDailyAdCount() ?? 0;
    return 'AdSafety['
        'session=$_fullscreenAdsShownInSession/${_params.maxFullscreenAdsPerSession}, '
        'hourly=${_hourlyAdTimestamps.length}/${_params.maxFullscreenAdsPerHour}, '
        'daily=$daily/${_params.maxFullscreenAdsPerDay}, '
        'CTR=$ctr%, '
        'clicks/min=${_clickTimestamps.length}, '
        'violations=${_decayedSuspiciousCountForDisplay()}, '
        'suspended=${DateTime.now().millisecondsSinceEpoch < _suspiciousPauseUntil}]';
  }

  /// Structured variant of [getStatus] — same underlying counters, JSON-able.
  /// Added for T23 (Compliance Report export); does not change [getStatus].
  static AdSafetySnapshot getStatusSnapshot() {
    final ctr = _totalImpressions > 0
        ? _totalClicks.toDouble() / _totalImpressions
        : 0.0;
    return AdSafetySnapshot(
      fullscreenAdsShownInSession: _fullscreenAdsShownInSession,
      maxFullscreenAdsPerSession: _params.maxFullscreenAdsPerSession,
      hourlyAdCount: _hourlyAdTimestamps.length,
      maxFullscreenAdsPerHour: _params.maxFullscreenAdsPerHour,
      dailyAdCount: _prefs?.getDailyAdCount() ?? 0,
      maxFullscreenAdsPerDay: _params.maxFullscreenAdsPerDay,
      clickThroughRate: ctr,
      suspiciousCtrThreshold: _params.suspiciousCtrThreshold,
      clicksLastMinute: _clickTimestamps.length,
      suspiciousViolationCount: _decayedSuspiciousCountForDisplay(),
      isSuspended:
          DateTime.now().millisecondsSinceEpoch < _suspiciousPauseUntil,
      dryRun: _params.dryRun,
    );
  }

  // ════════════════ PROGRESSIVE COOLDOWN ════════════════
  /// T25 re-audit fix: halve [_suspiciousViolationCount] every 24h of good
  /// behaviour since the last violation, mirroring the decay curve already
  /// used to soften the risk-score display (`_computeRiskScore`). Without
  /// this, a handful of old violations kept escalating the progressive
  /// cooldown exponent forever, since the only full reset was
  /// [resetForReinit] (rarely triggered in production).
  /// T68 — test-only seam to simulate elapsed time since the last violation,
  /// so decay behaviour (otherwise only reachable by waiting real hours) can
  /// be exercised deterministically.
  @visibleForTesting
  static void debugSetLastViolationTimestamp(int epochMs) {
    _lastViolationTimestamp = epochMs;
  }

  /// Round-31 audit — test-only seam to simulate a suspicious-pause window
  /// having naturally elapsed, without needing to fake real wall-clock
  /// advancement (the CTR ratio this interacts with doesn't depend on
  /// elapsed time at all, only [_suspiciousPauseUntil] does).
  @visibleForTesting
  static void debugExpireSuspiciousPause() {
    _suspiciousPauseUntil = 0;
  }

  /// T68 — [_suspiciousViolationCount] is only lazily re-decayed inside
  /// [_decayViolationCount], which runs on the *next* violation. Reading it
  /// between two violations (e.g. for [getStatusSnapshot]/a compliance
  /// report) could show a staler count than [_computeRiskScore]'s
  /// real-time-decayed `violationComponent`, even though both are meant to
  /// describe the same signal. This mirrors that real-time formula for
  /// **display only** — it never mutates [_suspiciousViolationCount] itself.
  static int _decayedSuspiciousCountForDisplay() {
    if (_lastViolationTimestamp == 0 || _suspiciousViolationCount == 0) {
      return _suspiciousViolationCount;
    }
    // Round-31 audit fix (MAJOR) — unclamped, a system clock rolled BACK
    // past `_lastViolationTimestamp` (manual change, NTP correction, a
    // timezone/DST shift the wrong way) makes this negative, and
    // `math.pow(0.5, negative)` is > 1 — e.g. 48h back yields a 4x
    // multiplier. That AMPLIFIES the violation count on every reinit
    // instead of decaying it, and — unlike the clock-forward throttle
    // bypass (MJ9, an architectural limit with no pure-Dart fix) — this one
    // is just a missing floor on elapsed time, fully fixable here.
    final hoursSince = math.max(
        0.0,
        (DateTime.now().millisecondsSinceEpoch - _lastViolationTimestamp) /
            (60 * 60 * 1000));
    final decayFactor = math.pow(0.5, hoursSince / 24);
    return (_suspiciousViolationCount * decayFactor).round();
  }

  static void _decayViolationCount() {
    if (_lastViolationTimestamp == 0) return;
    // Round-31 audit fix (MAJOR) — see _decayedSuspiciousCountForDisplay's
    // comment: unclamped, a rolled-back clock amplifies instead of decays.
    final hoursSince = math.max(
        0.0,
        (DateTime.now().millisecondsSinceEpoch - _lastViolationTimestamp) /
            (60 * 60 * 1000));
    final decayFactor = math.pow(0.5, hoursSince / 24);
    if (_suspiciousViolationCount > 0) {
      _suspiciousViolationCount =
          (_suspiciousViolationCount * decayFactor).round();
    }
    if (_scoreableViolationCount > 0) {
      _scoreableViolationCount =
          (_scoreableViolationCount * decayFactor).round();
    }
  }

  /// [countsTowardRiskScore]: false when this violation's signal is already
  /// reflected in another additive `_computeRiskScore` component (see
  /// [_scoreableViolationCount] doc) — it still always counts toward
  /// [_suspiciousViolationCount] for the progressive-cooldown escalation
  /// below, which must stay strong regardless of risk-score bookkeeping.
  static void _triggerSuspiciousPause(String reason,
      {bool countsTowardRiskScore = true}) {
    _decayViolationCount();
    _suspiciousViolationCount++;
    if (countsTowardRiskScore) _scoreableViolationCount++;
    _prefs?.setSuspiciousCount(_suspiciousViolationCount);

    // Round-31 audit fix (MINOR) — clamped to 4 (multiplier 16, 8h max with
    // the 30-minute base below), so `_maxSuspiciousPause` (24h) was dead —
    // a repeat offender never got past 8h. Raised to 6 (multiplier 64, 32h)
    // so the 24h ceiling below is the thing that actually caps it.
    final exponent = (_suspiciousViolationCount - 1).clamp(0, 6);
    int multiplier = 1;
    for (int i = 0; i < exponent; i++) {
      multiplier *= 2;
    }

    int pauseDuration = _baseSuspiciousPause * multiplier;
    if (pauseDuration > _maxSuspiciousPause) {
      pauseDuration = _maxSuspiciousPause;
    }

    _suspiciousPauseUntil =
        DateTime.now().millisecondsSinceEpoch + pauseDuration;
    _lastViolationTimestamp = DateTime.now().millisecondsSinceEpoch;
    SafeLogger.w(
      _tag,
      '⚠️ SUSPICIOUS: $reason | violation #$_suspiciousViolationCount '
      '| paused ${pauseDuration ~/ 60000} min',
    );
    // T25: emit even in dry-run — partners should see anomaly signals even
    // when the block itself is bypassed (dry-run only suppresses the block).
    _anomalySink?.call(AdAnomalyEvent(
      reason: reason,
      violationCount: _suspiciousViolationCount,
      pauseDurationMs: pauseDuration,
    ));
    _refreshRiskScore();
  }

  // ════════════════ POLICY RISK SCORE (T24) ════════════════

  /// 0-100 real-time policy risk score. Additive-only: never consulted by
  /// [canShowFullscreenAd] or [getStatus] — a dev/partner dashboard signal.
  /// Blends three linearly-weighted signals (no ML):
  ///  - CTR ratio vs [AdSafetyParams.suspiciousCtrThreshold] (weight 50) —
  ///    the clearest invalid-click signal.
  ///  - Suspicious-violation count, halved every 24h since the last
  ///    violation (weight 30).
  ///  - Rapid-resume ratio vs [AdSafetyParams.maxRapidResumesPerMinute]
  ///    (weight 20) — more false-positive prone, lowest weight.
  static int getPolicyRiskScore() => _computeRiskScore();

  static int _computeRiskScore() {
    final ctrRatio = _totalImpressions > 0 && _params.suspiciousCtrThreshold > 0
        ? (_totalClicks / _totalImpressions) / _params.suspiciousCtrThreshold
        : 0.0;
    final ctrComponent = ctrRatio.clamp(0.0, 1.0) * 50;

    var decayedViolations = _scoreableViolationCount.toDouble();
    if (_lastViolationTimestamp > 0) {
      // Round-31 audit fix (MAJOR) — see _decayedSuspiciousCountForDisplay's
      // comment: unclamped, a rolled-back clock amplifies instead of decays.
      final hoursSince = math.max(
          0.0,
          (DateTime.now().millisecondsSinceEpoch - _lastViolationTimestamp) /
              (60 * 60 * 1000));
      decayedViolations *= math.pow(0.5, hoursSince / 24);
    }
    final violationComponent = (decayedViolations / 5).clamp(0.0, 1.0) * 30;

    final resumeRatio = _params.maxRapidResumesPerMinute > 0
        ? _resumeTimestamps.length / _params.maxRapidResumesPerMinute
        : 0.0;
    final resumeComponent = resumeRatio.clamp(0.0, 1.0) * 20;

    return (ctrComponent + violationComponent + resumeComponent)
        .round()
        .clamp(0, 100);
  }

  static void _refreshRiskScore() {
    policyRiskScore.value = _computeRiskScore();
  }
}
