// On-device integration test for the Revenue dashboard demo (RevenueDemoPage).
//
// The dashboard is just `RevenuePanel()` (exported by the SDK,
// packages/ad_sdk/lib/src/widget/revenue_panel.dart) subscribed to
// `AdManager().events`, accumulating AdRevenueEvent values. Revenue may
// legitimately be $0 if no real onPaidEvent fired during this run — this
// test asserts the dashboard renders structurally against the real
// AdManager() without crashing, not any specific dollar value.
//
// Run with:
//   flutter test integration_test/revenue_dashboard_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Revenue dashboard renders RevenuePanel without crashing',
      (tester) async {
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
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Revenue dashboard tile');

    await tester.tap(tile);
    // RevenuePanel subscribes to a live event stream — avoid pumpAndSettle,
    // use a bounded pump window instead.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Revenue dashboard'), findsOneWidget);
    expect(
        find.textContaining(
            'Revenue is reported by AdMob/AppLovin via the OnPaidEvent'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
