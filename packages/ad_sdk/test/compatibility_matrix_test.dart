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
}
