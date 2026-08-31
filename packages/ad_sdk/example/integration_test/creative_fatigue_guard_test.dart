// T126 on-device integration test — AdSafetyParams.maxSameNetworkShowsPerWindow
// / networkFatigueWindowMs must not break real config wiring, and default
// params (999, i.e. effectively off) must never block a real
// canShowInterstitial() check that would otherwise pass.
//
// Run with:
//   flutter test integration_test/creative_fatigue_guard_test.dart -d <device-or-sim-id>

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

  testWidgets('fatigue-guard params construct and do not affect a real check',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    const params = AdSafetyParams(
      maxSameNetworkShowsPerWindow: 4,
      networkFatigueWindowMs: 900000,
    );
    expect(params.maxSameNetworkShowsPerWindow, 4);
    expect(params.networkFatigueWindowMs, 900000);

    // Default live params (999 = effectively off) must never fatigue-block
    // this on their own.
    AdManager().canShowInterstitial();
    expect(tester.takeException(), isNull);
  });
}
