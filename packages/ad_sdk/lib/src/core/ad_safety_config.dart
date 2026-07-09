import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../adaptive/adaptive_frequency.dart';
import '../state/ad_event.dart';
import '../utils/ad_preferences.dart';
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
  static bool _isColdStart = true;
  static final List<int> _clickTimestamps = [];
  static int _suspiciousPauseUntil = 0;
  static int _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
  static final List<int> _hourlyAdTimestamps = [];
  static final List<int> _resumeTimestamps = [];
  static int _totalImpressions = 0;
  static int _totalClicks = 0;
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
  static Future<void> init(
    AdPreferences prefs, {
    AdSafetyParams params = const AdSafetyParams(),
  }) async {
    _prefs = prefs;
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

  /// Check whether a fullscreen ad (inter/rewarded/app-open) can be shown.
  /// Honours `params.dryRun` — if set, blocks are logged but always return ok.
  static AdSafetyResult canShowFullscreenAd() {
    final result = _canShowFullscreenAdStrict();
    if (!result.canShow && _params.dryRun) {
      SafeLogger.w(
          _tag, '⚠️ dryRun: would have blocked (${result.reason}) — allowing');
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

  static AdSafetyResult _canShowFullscreenAdStrict() {
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

    if (_totalImpressions >= 5) {
      final ctr = _totalClicks.toDouble() / _totalImpressions.toDouble();
      if (ctr > _params.suspiciousCtrThreshold) {
        _triggerSuspiciousPause(
          'CTR anomaly: ${(ctr * 100).toInt()}% '
          '(threshold: ${(_params.suspiciousCtrThreshold * 100).toInt()}%)',
          // Same `ctr` value already feeds `ctrComponent` directly below —
          // don't also inflate `violationComponent` for it.
          countsTowardRiskScore: false,
        );
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
      _resumeTimestamps.clear();
      _refreshRiskScore();
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
  static void recordAdClick() {
    final now = DateTime.now().millisecondsSinceEpoch;
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
    SafeLogger.d(_tag, '📊 App went to background');
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

  static void resetSession() {
    _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
    _fullscreenAdsShownInSession = 0;
    _hourlyAdTimestamps.clear();
    _resumeTimestamps.clear();
    _totalImpressions = 0;
    _totalClicks = 0;
    // T24 re-audit fix: the click-spam sliding window is per-session state
    // too — leaving it here meant clicks from before a reset still counted
    // toward the spam threshold afterward.
    _clickTimestamps.clear();
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
    _prefs?.setSuspiciousCount(0);
    SafeLogger.d(_tag, '🔄 Session reset');
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
        'violations=$_suspiciousViolationCount, '
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
      suspiciousViolationCount: _suspiciousViolationCount,
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
  static void _decayViolationCount() {
    if (_lastViolationTimestamp == 0) return;
    final hoursSince =
        (DateTime.now().millisecondsSinceEpoch - _lastViolationTimestamp) /
            (60 * 60 * 1000);
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

    final exponent = (_suspiciousViolationCount - 1).clamp(0, 4);
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
      final hoursSince =
          (DateTime.now().millisecondsSinceEpoch - _lastViolationTimestamp) /
              (60 * 60 * 1000);
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
