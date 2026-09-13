// On-device integration test for the compatibility matrix.
//
// codex/independent-audit fix — this file was missing
// IntegrationTestWidgetsFlutterBinding.ensureInitialized() and the
// integration_test import, so it could not actually run through the
// integration_test package's device-driving mechanism at all (same gap
// separately found in T210's and T218's device test files). Fixed here.
//
// CompatibilityMatrix itself is pure Dart with no platform channels or
// widgets — there is no device-SPECIFIC behavior to prove here beyond
// "this compiles and runs correctly inside a real compiled app process",
// which this test still does. The real environment-reading half of the
// T215 fix (packages/ad_sdk/tool/validate_compatibility_matrix.dart,
// which shells out to a real `flutter` binary) is a CI/dev-machine tool
// script, not something that runs on a phone at all — its own smoke test
// is running it for real in a shell with a real Flutter install (see
// T215's Kết quả section in doc/task/done/).
//
// Run with:
//   flutter test integration_test/t215_compatibility_matrix_test.dart \
//     -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'T215 device smoke: the declared minimum matrix validates, and a '
      'below-minimum target is correctly rejected, on a real device',
      (tester) async {
    CompatibilityMatrix.validate(CompatibilityMatrix.minimum);
    expect(CompatibilityMatrix.minimum.length, greaterThanOrEqualTo(3));

    expect(
      CompatibilityMatrix.isSupported(const CompatibilityTarget(
          flutter: '3.34.0', // below the declared 3.35.1 minimum
          platform: CompatibilityPlatform.android,
          provider: CompatibilityProvider.admob,
          apiLevel: 34)),
      isFalse,
      reason: 'T215 — the old floor-only check would have accepted this; '
          'confirming the real comparison still rejects it on-device',
    );
  });
}
