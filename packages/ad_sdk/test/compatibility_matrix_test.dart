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

    test('a platform/provider combination with no declared minimum is '
        'NOT supported by default (fail-safe, not fail-open)', () {
      expect(
        CompatibilityMatrix.isSupported(const CompatibilityTarget(
            flutter: '99.99.99', // absurdly high — proves this isn't an
            // apiLevel/version problem, there is just no (ios, appLovin)
            // entry in CompatibilityMatrix.minimum at all today
            platform: CompatibilityPlatform.ios,
            provider: CompatibilityProvider.appLovin,
            apiLevel: 999)),
        isFalse,
        reason: 'T215 — no minimum is declared for (ios, appLovin) today; '
            'an undeclared combination must not silently pass',
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
