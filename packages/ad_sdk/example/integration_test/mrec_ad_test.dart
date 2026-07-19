// On-device integration test for the MREC demo (MrecDemoPage).
//
// Structurally a clone of BannerDemoPage (see banner_ad_test.dart) but for the
// fixed 300x250 rectangle slot — navigates to the MREC demo, verifies the
// demo page renders, and exercises the same route push+pop pause/resume path
// (RouteAware via `adRouteObserver`).
//
// Ad *content*/fill is never guaranteed (especially on a simulator), so this
// only asserts the demo page + push/pop survive without crashing — not that a
// specific creative loaded.
//
// Run with:
//   flutter test integration_test/mrec_ad_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
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

  testWidgets('MREC renders and survives a route push+pop', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('MREC ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list the MREC ad tile');

    await tester.tap(tile);
    // MREC has no auto-refresh timer like banner, but give it a bounded
    // window to load same as banner_ad_test for consistency.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.text('MREC demo'), findsOneWidget);
    expect(find.text('Push another screen (verifies pause/resume)'),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    // Push the second screen — RouteAware should pause/hide the MREC.
    await tester.tap(find.text('Push another screen (verifies pause/resume)'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Second route'), findsOneWidget);
    expect(find.text('MREC pauses on previous'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Pop back — MREC on the first screen should resume without crashing.
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('MREC demo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
