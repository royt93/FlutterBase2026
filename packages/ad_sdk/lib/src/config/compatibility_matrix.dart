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
  ];

  static bool isSupported(CompatibilityTarget target) =>
      target.apiLevel >=
          (target.platform == CompatibilityPlatform.android ? 23 : 15) &&
      target.flutter.isNotEmpty;

  static void validate(Iterable<CompatibilityTarget> targets) {
    if (targets.isEmpty || targets.any((t) => !isSupported(t))) {
      throw ArgumentError('compatibility matrix contains unsupported targets');
    }
  }
}
