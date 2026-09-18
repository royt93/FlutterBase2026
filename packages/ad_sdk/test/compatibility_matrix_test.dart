import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('minimum matrix covers provider/platform dimensions', () {
    CompatibilityMatrix.validate(CompatibilityMatrix.minimum);
    expect(CompatibilityMatrix.minimum.map((t) => t.provider).toSet(),
        containsAll(CompatibilityProvider.values));
    expect(
        CompatibilityMatrix.minimum.map((t) => t.platform).toSet(),
        containsAll(
            [CompatibilityPlatform.android, CompatibilityPlatform.ios]));
  });

  test('unsupported API floor is rejected', () {
    expect(
        () => CompatibilityMatrix.validate([
              const CompatibilityTarget(
                  flutter: '3.35.1',
                  platform: CompatibilityPlatform.android,
                  provider: CompatibilityProvider.admob,
                  apiLevel: 1),
            ]),
        throwsArgumentError);
  });

  group('T215 audit fix — isSupported genuinely compares against the '
      'declared minimum, not a hardcoded constant checked against itself',
      () {
    test('a Flutter version BELOW the declared minimum is rejected', () {
      expect(
        CompatibilityMatrix.isSupported(const CompatibilityTarget(
            flutter: '3.34.0', // below the declared 3.35.1 minimum
            platform: CompatibilityPlatform.android,
            provider: CompatibilityProvider.admob,
            apiLevel: 34)),
        isFalse,
        reason: 'T215 — the old floor-only check (flutter.isNotEmpty) '
            'would have accepted ANY non-empty version string here, '
            'including one below the SDK\'s own declared minimum',
      );
    });

    test('a Flutter version AT the declared minimum is accepted', () {
      expect(
        CompatibilityMatrix.isSupported(const CompatibilityTarget(
            flutter: '3.35.1',
            platform: CompatibilityPlatform.android,
            provider: CompatibilityProvider.admob,
            apiLevel: 34)),
        isTrue,
      );
    });

    test(
        'a Flutter version ABOVE the declared minimum is REJECTED — an '
        'unapproved newer pin must not silently pass just for being newer',
        () {
      expect(
        CompatibilityMatrix.isSupported(const CompatibilityTarget(
            flutter: '3.41.9',
            platform: CompatibilityPlatform.android,
            provider: CompatibilityProvider.admob,
            apiLevel: 34)),
        isFalse,
        reason: 'second audit round — the old `>=` floor accepted ANY '
            'newer Flutter version, so an unreviewed CI pin bump would '
            'have passed this gate silently. Exact-match on flutter '
            'catches that.',
      );
    });

    test(
        'a higher API level than the declared minimum is still accepted '
        '(API levels stay backward compatible, unlike Flutter versions)',
        () {
      expect(
        CompatibilityMatrix.isSupported(const CompatibilityTarget(
            flutter: '3.35.1',
            platform: CompatibilityPlatform.android,
            provider: CompatibilityProvider.admob,
            apiLevel: 99)),
        isTrue,
      );
    });

    // Audit round 42, MINOR — (ios, appLovin) used to have no declared
    // minimum at all, even though the adapter code handles it fine; this
    // test used to demonstrate that gap. It's fixed below by declaring the
    // missing entry, which also makes the "undeclared combination" scenario
    // this test used to demonstrate impossible to construct within today's
    // 2×2 (platform × provider) enum space — every combination now has a
    // declared minimum, so the fail-safe `match.isEmpty → false` branch in
    // [CompatibilityMatrix.isSupported] has no real-world example left to
    // demonstrate it with until a 3rd platform or provider is ever added.
    test('every platform × provider combination has a declared minimum '
        '(no more silent gaps for isSupported\'s fail-safe branch to hide '
        'behind)', () {
      for (final platform in CompatibilityPlatform.values) {
        for (final provider in CompatibilityProvider.values) {
          expect(
            CompatibilityMatrix.minimum.any(
                (m) => m.platform == platform && m.provider == provider),
            isTrue,
            reason: '($platform, $provider) has no declared minimum',
          );
        }
      }
    });

    test('(ios, appLovin) is now supported at its declared minimum', () {
      expect(
        CompatibilityMatrix.isSupported(const CompatibilityTarget(
            flutter: '3.35.1',
            platform: CompatibilityPlatform.ios,
            provider: CompatibilityProvider.appLovin,
            apiLevel: 26)),
        isTrue,
        reason: 'the newly-declared (ios, appLovin) minimum must actually '
            'be honoured by isSupported, not just present in the list',
      );
    });

    test('an API level below the declared minimum is rejected even with '
        'a Flutter version above it', () {
      expect(
        CompatibilityMatrix.isSupported(const CompatibilityTarget(
            flutter: '3.99.0',
            platform: CompatibilityPlatform.android,
            provider: CompatibilityProvider.admob,
            apiLevel: 1)),
        isFalse,
      );
    });
  });
}
