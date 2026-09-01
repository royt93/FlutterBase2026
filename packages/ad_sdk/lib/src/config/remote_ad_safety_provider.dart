import '../core/ad_safety_config.dart';

/// T88 — provider-agnostic hook for remotely-controlled [AdSafetyParams]
/// overrides (Firebase Remote Config, a self-hosted config API, a feature-flag
/// service, ...). The SDK has no opinion on where the values come from and
/// takes no dependency on any specific remote-config package — implement
/// this interface with whatever the host app already uses.
///
/// ```dart
/// class MyFirebaseSafetyProvider implements RemoteAdSafetyProvider {
///   @override
///   Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
///     final remote = FirebaseRemoteConfig.instance;
///     await remote.fetchAndActivate();
///     final json = remote.getString('ad_safety_params');
///     return json.isEmpty ? null : jsonDecode(json) as Map<String, dynamic>;
///   }
/// }
///
/// AdManager().initialize(
///   config: myConfig,
///   remoteSafetyProvider: MyFirebaseSafetyProvider(),
/// );
/// ```
abstract class RemoteAdSafetyProvider {
  /// Returns override values keyed by [AdSafetyParams] field name (e.g.
  /// `{'maxFullscreenAdsPerDay': 8}`), or `null`/throws if unavailable —
  /// either way, [AdManager.initialize] falls back to the local
  /// [AdConfig.safety] unchanged. Unknown keys and values that fail
  /// [applyRemoteSafetyOverrides]'s validation are silently skipped, not
  /// fatal — a malformed remote payload must never block SDK init.
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides();
}

/// Merges validated [overrides] onto [local], keeping [local]'s value for
/// any key that's missing, has the wrong type, or fails the sanity check
/// below (negative durations/counts, an out-of-[0,1] CTR threshold, ...).
/// Never throws.
AdSafetyParams applyRemoteSafetyOverrides(
  AdSafetyParams local,
  Map<String, dynamic> overrides,
) {
  // Round-30 audit (MAJOR) — only `dryRun` was guarded against a
  // safety-defeating remote payload (see `AdSafetyConfig`'s R12-A
  // `applyDryRunReleaseGuard`, added for exactly that threat model). These
  // six numeric fields had no ceiling at all: a compromised/malicious/
  // buggy remote config could set `minTimeBetweenFullscreenAds: 0` (kills
  // the anti-fraud throttle outright) or any cap field to an arbitrarily
  // large number (functionally unlimited ads), with nothing here to stop
  // it. `max` keeps every field within a generous-but-bounded range;
  // `min1` additionally requires a real throttle floor (`>= 1`, not `>= 0`)
  // for the two fields whose whole job is "not zero".
  // Round-30 audit (MINOR) — was `v is int` only, so a remote-config
  // backend that JSON-emits `8.0` for a whole-number field (common —
  // several serializers don't distinguish int/double) was silently dropped
  // in favor of the local default, unlike `unitDouble` below which already
  // accepts `num`. Accepts a whole-valued `double` too.
  int? posInt(String key, {required int max, int min = 0}) {
    final v = overrides[key];
    final int? asInt = switch (v) {
      int i => i,
      double d when d == d.truncateToDouble() => d.toInt(),
      _ => null,
    };
    return (asInt != null && asInt >= min && asInt <= max) ? asInt : null;
  }

  double? unitDouble(String key) {
    final v = overrides[key];
    return (v is num && v >= 0.0 && v <= 1.0) ? v.toDouble() : null;
  }

  bool? boolVal(String key) {
    final v = overrides[key];
    return v is bool ? v : null;
  }

  return local.copyWith(
    minTimeBetweenFullscreenAds: posInt('minTimeBetweenFullscreenAds',
        min: 1, max: 3600000 /* 1h */),
    maxFullscreenAdsPerSession:
        posInt('maxFullscreenAdsPerSession', max: 100),
    minTimeAppOpenResume:
        posInt('minTimeAppOpenResume', min: 1, max: 3600000 /* 1h */),
    maxClicksPerMinute: posInt('maxClicksPerMinute', max: 60),
    maxFullscreenAdsPerDay: posInt('maxFullscreenAdsPerDay', max: 500),
    maxFullscreenAdsPerHour: posInt('maxFullscreenAdsPerHour', max: 100),
    minSessionDurationBeforeAd:
        posInt('minSessionDurationBeforeAd', max: 3600000 /* 1h */),
    suspiciousCtrThreshold: unitDouble('suspiciousCtrThreshold'),
    maxRapidResumesPerMinute: posInt('maxRapidResumesPerMinute', max: 60),
    dryRun: boolVal('dryRun'),
    adToBackgroundSignalWindowMs:
        posInt('adToBackgroundSignalWindowMs', max: 3600000 /* 1h */),
  );
}
