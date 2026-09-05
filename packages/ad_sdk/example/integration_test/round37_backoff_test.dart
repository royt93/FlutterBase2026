// On-device integration test for round-37 audit — the exponential backoff
// integer-overflow fix.
//
// Why on-device at all: this is pure Dart math with no platform channel and
// no widget involved (full bit-level coverage lives in `test/ad_slot_test.dart`)
// — but `int` arithmetic overflow behavior is a property of the COMPILED
// runtime the code actually executes on. Running it once here proves the
// same fixed formula also holds under the release/profile ARM64 Dart runtime
// a real device uses, not only the desktop VM `flutter test` runs on.
//
// Run with:
//   flutter test integration_test/round37_backoff_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Backoff.compute() stays at maxMs past 51 consecutive failures on the '
      'real device runtime, does not collapse to baseMs via int overflow',
      (tester) async {
    const backoff = Backoff(); // baseMs: 15s, maxMs: 30min
    for (final failures in [51, 64, 100, 1000]) {
      expect(backoff.compute(failures), backoff.maxMs,
          reason: 'consecutiveFailures=$failures must still be clamped to '
              'maxMs on this device\'s runtime, not collapse to baseMs');
    }
  });
}
