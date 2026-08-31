// T122 on-device integration test — WaterfallTuner must wire into the real
// AdManager().events stream and answer recommendation() without throwing
// (opt-in, observe-only: this alone never switches providers).
//
// Run with:
//   flutter test integration_test/waterfall_tuner_test.dart -d <device-or-sim-id>

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

  testWidgets('WaterfallTuner subscribes to the real event stream and scores',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tuner = WaterfallTuner();
    AdManager().enableWaterfallTuner(tuner);
    addTearDown(AdManager().disableWaterfallTuner);

    await AdManager().loadInterstitial();
    await tester.pump(const Duration(milliseconds: 200));

    // Not enough samples yet on a fresh run — must return null, not throw.
    final rec = tuner.recommendation(
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      currentProvider: '[AdMob]',
    );
    expect(rec, isNull);
    expect(tester.takeException(), isNull);
  });
}
