// T150 — RevenueDemoPage's "type match" demo (RevenueIntegrityLedger, T145)
// on a real device: simulating a same-placement banner+interstitial show
// then interstitial-only revenue must leave exactly the banner's show
// still pending, not clear it by mistake.
//
// Run with:
//   flutter test integration_test/revenue_ledger_type_match_demo_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
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
      'simulating a same-placement banner+interstitial show then '
      'interstitial-only revenue leaves the banner pending on a real '
      'device', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Revenue dashboard');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list Revenue tile');

    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final button = find.text('Simulate 2 shows\n(banner + interstitial)');
    await tester.scrollUntilVisible(button, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Pending: 2'), findsOneWidget);

    final revenueButton = find.text('Simulate revenue\n(interstitial only)');
    await tester.scrollUntilVisible(revenueButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(revenueButton);
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Pending: 1'), findsOneWidget,
        reason: 'the banner\'s pending show must not be cleared by the '
            'interstitial\'s revenue event — T150');
  });
}
