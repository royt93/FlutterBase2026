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
  int? posInt(String key) {
    final v = overrides[key];
    return (v is int && v >= 0) ? v : null;
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
    minTimeBetweenFullscreenAds: posInt('minTimeBetweenFullscreenAds'),
    maxFullscreenAdsPerSession: posInt('maxFullscreenAdsPerSession'),
    minTimeAppOpenResume: posInt('minTimeAppOpenResume'),
    maxClicksPerMinute: posInt('maxClicksPerMinute'),
    maxFullscreenAdsPerDay: posInt('maxFullscreenAdsPerDay'),
    maxFullscreenAdsPerHour: posInt('maxFullscreenAdsPerHour'),
    minSessionDurationBeforeAd: posInt('minSessionDurationBeforeAd'),
    suspiciousCtrThreshold: unitDouble('suspiciousCtrThreshold'),
    maxRapidResumesPerMinute: posInt('maxRapidResumesPerMinute'),
    dryRun: boolVal('dryRun'),
    adToBackgroundSignalWindowMs: posInt('adToBackgroundSignalWindowMs'),
  );
}
