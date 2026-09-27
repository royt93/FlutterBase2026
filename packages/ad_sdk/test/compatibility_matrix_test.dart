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
                  flutter: '3.38.1',
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
            flutter: '3.34.0', // below the declared 3.38.1 minimum
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
            flutter: '3.38.1',
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
            flutter: '3.38.1',
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
            flutter: '3.38.1',
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

  // T221 — the matrix used to declare 3.35.1 while pubspec required
  // >=3.38.1 and CI pinned 3.38.1, so the real CI Flutter was rejected.
  group('T221 — Flutter floor matches pubspec + CI (3.38.1)', () {
    CompatibilityTarget at(String flutter) => CompatibilityTarget(
        flutter: flutter,
        platform: CompatibilityPlatform.android,
        provider: CompatibilityProvider.admob,
        apiLevel: 34);

    test('every declared minimum uses the 3.38.1 floor', () {
      expect(CompatibilityMatrix.minimum.map((t) => t.flutter).toSet(),
          {'3.38.1'});
    });

    test('the old stale 3.35.1 floor is now rejected', () {
      expect(CompatibilityMatrix.isSupported(at('3.35.1')), isFalse);
    });

    test('3.37.x (just below the floor) is rejected', () {
      expect(CompatibilityMatrix.isSupported(at('3.37.9')), isFalse);
    });

    test('3.38.0 (patch below the floor) is rejected', () {
      expect(CompatibilityMatrix.isSupported(at('3.38.0')), isFalse);
    });

    test('3.38.1 (exactly the floor) is accepted', () {
      expect(CompatibilityMatrix.isSupported(at('3.38.1')), isTrue);
    });

    test('3.38.2 (above floor) is still rejected — exact-match policy kept',
        () {
      expect(CompatibilityMatrix.isSupported(at('3.38.2')), isFalse);
    });

    test('empty / malformed version strings are rejected', () {
      expect(CompatibilityMatrix.isSupported(at('')), isFalse);
      expect(CompatibilityMatrix.isSupported(at('3.38.1 ')), isFalse);
      expect(CompatibilityMatrix.isSupported(at('v3.38.1')), isFalse);
    });

    test('validate throws on an empty target list', () {
      expect(() => CompatibilityMatrix.validate(const []), throwsArgumentError);
    });

    test('validate rejection names expected vs actual flutter', () {
      expect(
          () => CompatibilityMatrix.validate([at('3.35.1')]),
          throwsA(isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              allOf(contains('flutter=3.35.1'),
                  contains('declared minimum flutter=3.38.1')))));
    });
  });
}
