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
      // Round-31 audit fix — `d == d.truncateToDouble()` is true for
      // `double.infinity` (and `-infinity`), and `.toInt()` on either
      // throws `UnsupportedError` rather than returning a value. A remote
      // payload with a field serialized as `1e400` (JSON has no literal
      // Infinity, but `jsonDecode` produces it from an out-of-range
      // exponent) would crash the caller instead of being rejected like
      // every other malformed value here. `isFinite` excludes NaN too.
      double d when d.isFinite && d == d.truncateToDouble() => d.toInt(),
      _ => null,
    };
    return (asInt != null && asInt >= min && asInt <= max) ? asInt : null;
  }

  double? unitDouble(String key) {
    final v = overrides[key];
    // Round-31 audit fix (MINOR) — `posInt`'s two throttle fields require
    // `min: 1` because "the whole job of this field is to not be zero" (see
    // above); this field's job is the same — a 0.0 threshold means ANY
    // click at all trips a CTR anomaly for every user, which is only ever
    // reachable in practice via a backend serialization bug (a missing
    // field defaulting to `0`), not a deliberate setting. Unlike those two
    // int fields, this is a double with no earlier explicit floor at all.
    return (v is num && v > 0.0 && v <= 1.0) ? v.toDouble() : null;
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
    // Round-31 audit fix (MINOR) — T126's network-fatigue guard had
    // `copyWith` support but was never actually reachable from remote
    // config: every other numeric field here is remote-tunable, so a
    // mediation incident (one network winning repeatedly, creative
    // fatigue) had no way to be tightened/loosened without a build.
    // `min: 1` on the window mirrors the two throttle fields above — a
    // 0ms window makes the "same network shown recently" check
    // unsatisfiable, silently disabling the guard.
    maxSameNetworkShowsPerWindow:
        posInt('maxSameNetworkShowsPerWindow', max: 100),
    networkFatigueWindowMs:
        posInt('networkFatigueWindowMs', min: 1, max: 3600000 /* 1h */),
  );
}
