enum CompatibilityPlatform { android, ios }

enum CompatibilityProvider { admob, appLovin }

class CompatibilityTarget {
  const CompatibilityTarget(
      {required this.flutter,
      required this.platform,
      required this.provider,
      required this.apiLevel});
  final String flutter;
  final CompatibilityPlatform platform;
  final CompatibilityProvider provider;
  final int apiLevel;
}

/// Minimum PR matrix plus a larger nightly matrix. Kept as data so CI and
/// consuming tooling can enumerate the same supported combinations.
class CompatibilityMatrix {
  static const minimum = <CompatibilityTarget>[
    CompatibilityTarget(
        flutter: '3.35.1',
        platform: CompatibilityPlatform.android,
        provider: CompatibilityProvider.admob,
        apiLevel: 34),
    CompatibilityTarget(
        flutter: '3.35.1',
        platform: CompatibilityPlatform.android,
        provider: CompatibilityProvider.appLovin,
        apiLevel: 34),
    CompatibilityTarget(
        flutter: '3.35.1',
        platform: CompatibilityPlatform.ios,
        provider: CompatibilityProvider.admob,
        apiLevel: 26),
    // Audit round 42, MINOR — was missing entirely, so `isSupported`
    // reported (ios, appLovin) as unsupported even though the adapter code
    // handles it fine (no iOS-gated restriction on AppLovin anywhere in
    // applovin_adapter.dart). Self-inflicted doc/CI gap, currently inert
    // since the `compatibility-matrix` CI job only runs
    // `platform: [android]` today — but would hard-fail CI the moment
    // anyone widens that matrix to iOS without this entry.
    CompatibilityTarget(
        flutter: '3.35.1',
        platform: CompatibilityPlatform.ios,
        provider: CompatibilityProvider.appLovin,
        apiLevel: 26),
  ];

  /// Audit fix (post-T215) — this used to be a floor check against a
  /// hardcoded constant (`apiLevel >= 23/15`, `flutter.isNotEmpty`) that
  /// [target] would pass no matter what real value it carried, since
  /// [validate_compatibility_matrix.dart] (the CI tool that calls this)
  /// also hardcoded its own `flutter`/`apiLevel` values rather than
  /// reading the real environment — the whole gate checked a constant
  /// against itself and could never fail, so a genuinely incompatible CI
  /// Flutter/API-level bump would have passed silently. Now compares
  /// [target] against the declared [minimum] entry for the SAME
  /// platform+provider: no matching entry (nothing declared as minimum
  /// for that combination) is NOT supported by default, matching this
  /// SDK's fail-safe convention elsewhere rather than fail-open.
  ///
  /// Second audit round found this still fail-open on the Flutter version:
  /// a `>=` floor let an UNAPPROVED newer Flutter pin bump pass silently,
  /// exactly the scenario this gate exists to catch — a new Flutter release
  /// is not proven compatible just by being newer. `apiLevel` keeps the
  /// floor check (a higher Android API level is genuinely still supported,
  /// that's what API-level backward compatibility means); `flutter` is now
  /// an exact match against the declared, reviewed [minimum] entry.
  static bool isSupported(CompatibilityTarget target) {
    final match = minimum.where(
        (m) => m.platform == target.platform && m.provider == target.provider);
    if (match.isEmpty) return false;
    final min = match.first;
    return target.apiLevel >= min.apiLevel && target.flutter == min.flutter;
  }

  static void validate(Iterable<CompatibilityTarget> targets) {
    if (targets.isEmpty || targets.any((t) => !isSupported(t))) {
      throw ArgumentError('compatibility matrix contains unsupported targets');
    }
  }
}
