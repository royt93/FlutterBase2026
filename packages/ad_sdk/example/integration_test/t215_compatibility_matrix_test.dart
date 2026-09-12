import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T215 Android smoke: minimum matrix validates on device',
      (tester) async {
    CompatibilityMatrix.validate(CompatibilityMatrix.minimum);
    expect(CompatibilityMatrix.minimum.length, greaterThanOrEqualTo(3));
  });
}
