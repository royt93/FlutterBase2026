// T123 on-device integration test — JourneyPrefetcher.notifySignal() must
// wire into the real AdManager()/event stream and never throw when a host
// declares a journey signal.
//
// Run with:
//   flutter test integration_test/journey_prefetcher_test.dart -d <device-or-sim-id>

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

  testWidgets('JourneyPrefetcher.notifySignal() runs against the live SDK',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final prefetcher = JourneyPrefetcher();
    AdManager().enableJourneyPrefetcher(prefetcher);
    addTearDown(AdManager().disableJourneyPrefetcher);

    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
  });
}
