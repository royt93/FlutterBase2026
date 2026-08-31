// T129 on-device integration test — AdManager().buildMonetizationDigitalTwin()
// must build from the SDK's real compliance log post-init and answer
// forecastDailyCap() without throwing, without ever firing a real ad
// request.
//
// Run with:
//   flutter test integration_test/digital_twin_test.dart -d <device-or-sim-id>

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

  testWidgets('buildMonetizationDigitalTwin() forecasts from the real log',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final twin = AdManager().buildMonetizationDigitalTwin();
    expect(twin, isNotNull,
        reason: 'a live event log exists once the SDK has initialised');

    final forecast = twin!.forecastDailyCap(3);
    expect(forecast, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
