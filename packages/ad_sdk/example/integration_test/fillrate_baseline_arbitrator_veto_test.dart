// T112 on-device integration test — MonetizationArbitrator wired with a real
// FillRateBaselineMonitor must accept the constructor param and produce a
// decision without throwing, proving the two real objects connect on device
// (not just in a unit-test double).
//
// Run with:
//   flutter test integration_test/fillrate_baseline_arbitrator_veto_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'MonetizationArbitrator(fillRateBaselineMonitor:) wires a real regression signal',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    await AdManager().enableFillRateBaselineMonitor();
    addTearDown(AdManager().disableFillRateBaselineMonitor);
    final baseline = AdManager().fillRateBaselineMonitor;
    expect(baseline, isNotNull);

    AdManager().enableArbitrator(
      MonetizationArbitrator(fillRateBaselineMonitor: baseline),
    );
    addTearDown(AdManager().disableArbitrator);

    final decision = AdManager().arbitrator!.decide(AdSlotType.interstitial);
    expect(decision, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
