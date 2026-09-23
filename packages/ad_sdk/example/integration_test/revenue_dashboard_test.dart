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
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scroll_helpers.dart';

// On a real device the splash flow can hit BOTH the real ATT system prompt
// AND a real UMP consent form before initialize() ever completes -- each
// has its own internal 20s timeout when nothing dismisses it headlessly (see
// AttConsent's `requestAttIfNeeded` / UmpConsent's dismiss-timeout log line),
// so worst case is ~40s of that alone before init even starts resolving.
// Budget well past that (same fix already applied in
// debug_overlay_doctor_test.dart -- 2026-08-18 fork-review: this file hit the
// tighter 30s window's real failure mode on-device).
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Revenue dashboard renders RevenuePanel without crashing',
      (tester) async {
    // HomePage's demo list is a viewport-lazy ListView — "Revenue dashboard"
    // is the 9th of 10 tiles and isn't built at all at default phone height
    // (see compliance_export_test.dart for the same issue on the last tile).
    // Use a tall synthetic viewport so every tile is within the build/cache
    // extent instead of requiring a real scroll gesture.
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Revenue dashboard');
    var foundTile = false;
    // 120 * 500ms = 60s — widened from 20s (2026-09-23): found flaky (pass
    // once, fail once) across two runs despite the tall viewport above;
    // real-device cold start/navigation can outlast a fixed 20s window
    // under load.
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Revenue dashboard tile');

    await tester.scrollUntilVisibleAndSettle(tile, 200,
        scrollable: find.byType(Scrollable).first);
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
