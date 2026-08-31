// T127 on-device integration test — SelfHealingObserver (observe-only
// prototype) must wire into the real event stream without ever switching
// providers itself — it only ever emits a recommendation event.
//
// Run with:
//   flutter test integration_test/self_healing_observer_test.dart -d <device-or-sim-id>

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
      'SelfHealingObserver observes real events without switching providers',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final providerBefore = AdManager().config?.provider;

    final observer = SelfHealingObserver();
    AdManager().enableSelfHealingObserver(observer);
    addTearDown(AdManager().disableSelfHealingObserver);

    await AdManager().loadInterstitial();
    await tester.pump(const Duration(milliseconds: 200));

    // Observe-only: the active provider must never change on its own.
    expect(AdManager().config?.provider, providerBefore);
    expect(tester.takeException(), isNull);
  });
}
