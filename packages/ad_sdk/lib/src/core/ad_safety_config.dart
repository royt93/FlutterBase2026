import 'package:flutter/foundation.dart';

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
    minTimeBetweenFullscreenAds: 2000,      // 2 s
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
  static bool _isColdStart = true;
  static final List<int> _clickTimestamps = [];
  static int _suspiciousPauseUntil = 0;
  static int _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
  static final List<int> _hourlyAdTimestamps = [];
  static final List<int> _resumeTimestamps = [];
  static int _totalImpressions = 0;
  static int _totalClicks = 0;
  static int _suspiciousViolationCount = 0;
  static AdPreferences? _prefs;

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
  }

  /// Check whether a fullscreen ad (inter/rewarded/app-open) can be shown.
  /// Honours `params.dryRun` — if set, blocks are logged but always return ok.
  static AdSafetyResult canShowFullscreenAd() {
    final result = _canShowFullscreenAdStrict();
    if (!result.canShow && _params.dryRun) {
      SafeLogger.w(_tag,
          '⚠️ dryRun: would have blocked (${result.reason}) — allowing');
      return AdSafetyResult(true, 'dryRun-bypass(${result.reason})');
    }
    return result;
  }

  static AdSafetyResult _canShowFullscreenAdStrict() {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (now < _suspiciousPauseUntil) {
      final remainingMs = _suspiciousPauseUntil - now;
      SafeLogger.d(_tag, '🛡️ Ads paused, remaining=${_fmtWait(remainingMs)}');
      return AdSafetyResult(false, 'Suspended: ${_fmtWait(remainingMs)} remaining');
    }

    final sessionDuration = now - _sessionStartTime;
    if (sessionDuration < _params.minSessionDurationBeforeAd) {
      final waitMs = _params.minSessionDurationBeforeAd - sessionDuration;
      SafeLogger.d(_tag,
          '🛡️ Session too young (${_fmtWait(sessionDuration)}), wait ${_fmtWait(waitMs)}');
      return AdSafetyResult(false, 'Session too young: wait ${_fmtWait(waitMs)}');
    }

    if (_fullscreenAdsShownInSession >= _params.maxFullscreenAdsPerSession) {
      SafeLogger.d(_tag, '🛡️ Session limit: $_fullscreenAdsShownInSession/${_params.maxFullscreenAdsPerSession}');
      return AdSafetyResult(false, 'Session limit: $_fullscreenAdsShownInSession ads');
    }

    _hourlyAdTimestamps.removeWhere((t) => now - t > 3600000);
    if (_hourlyAdTimestamps.length >= _params.maxFullscreenAdsPerHour) {
      SafeLogger.d(_tag, '🛡️ Hourly cap: ${_hourlyAdTimestamps.length}/${_params.maxFullscreenAdsPerHour}');
      return AdSafetyResult(false, 'Hourly cap: ${_hourlyAdTimestamps.length} ads');
    }

    final dailyCount = _prefs?.getDailyAdCount() ?? 0;
    if (dailyCount >= _params.maxFullscreenAdsPerDay) {
      SafeLogger.d(_tag, '🛡️ Daily limit: $dailyCount/${_params.maxFullscreenAdsPerDay}');
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
      SafeLogger.d(_tag, '🛡️ Skipping App Open on cold start (one-shot, will allow next resume)');
      _isColdStart = false; // consumed regardless — first resume is always skipped
      return const AdSafetyResult(false,
          'cold start (one-shot — next resume will pass)');
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
    if (_resumeTimestamps.length > _params.maxRapidResumesPerMinute) {
      final reason =
          'rapid resume (${_resumeTimestamps.length} resumes/min > cap ${_params.maxRapidResumesPerMinute}, wait up to 60s)';
      SafeLogger.d(_tag, '🛡️ App Open on resume blocked: $reason');
      _resumeTimestamps.clear();
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
  }

  /// Record a banner ad impression (initial load only, not refreshes).
  /// Counts towards total impressions for CTR calculation.
  static void recordBannerImpression() {
    _totalImpressions++;
    SafeLogger.d(_tag, '📊 Banner impression | totalImpressions=$_totalImpressions');
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
      _triggerSuspiciousPause('Click spam: ${_clickTimestamps.length} clicks/min');
      _clickTimestamps.clear();
    }
  }

  /// Record that the app went to background.
  static void recordAppWentBackground() {
    _lastBackgroundTime = DateTime.now().millisecondsSinceEpoch;
    SafeLogger.d(_tag, '📊 App went to background');
  }

  static int getSessionAdCount() => _fullscreenAdsShownInSession;

  static void resetSession() {
    _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
    _fullscreenAdsShownInSession = 0;
    _hourlyAdTimestamps.clear();
    _resumeTimestamps.clear();
    _totalImpressions = 0;
    _totalClicks = 0;
    SafeLogger.d(_tag, '🔄 Session reset');
  }

  /// Full reset for destroy() + re-initialize() flows.
  /// Unlike [resetSession], this also resets [_isColdStart] and
  /// [_suspiciousPauseUntil] so the SDK behaves as if freshly started.
  static void resetForReinit() {
    resetSession();
    _isColdStart = true;
    _lastFullscreenAdTime = 0;
    _lastBackgroundTime = 0;
    _suspiciousPauseUntil = 0;
    _suspiciousViolationCount = 0; // Fix #35: reset violation count for clean reinit
    _clickTimestamps.clear();
    SafeLogger.d(_tag, '🔄 Full reinit reset (coldStart restored)');
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

  // ════════════════ PROGRESSIVE COOLDOWN ════════════════
  static void _triggerSuspiciousPause(String reason) {
    _suspiciousViolationCount++;
    _prefs?.incrementSuspiciousCount();

    final exponent = (_suspiciousViolationCount - 1).clamp(0, 4);
    int multiplier = 1;
    for (int i = 0; i < exponent; i++) {
      multiplier *= 2;
    }

    int pauseDuration = _baseSuspiciousPause * multiplier;
    if (pauseDuration > _maxSuspiciousPause) pauseDuration = _maxSuspiciousPause;

    _suspiciousPauseUntil = DateTime.now().millisecondsSinceEpoch + pauseDuration;
    SafeLogger.w(
      _tag,
      '⚠️ SUSPICIOUS: $reason | violation #$_suspiciousViolationCount '
      '| paused ${pauseDuration ~/ 60000} min',
    );
  }
}
