// On-device integration test for the Slot state panel demo
// (StatePanelDemoPage).
//
// Asserts the live AdSlot state panel renders the real adapter's three
// singleton slots (App Open / Interstitial / Rewarded — banner/mrec/native
// became per-widget-instance in T65 and have no single slot to show here)
// and that the manual destroy/reinit controls actually reach `AdManager()`
// — destroy nulls the adapter (panel falls back to "SDK not initialised
// yet"), reinit restores it — without crashing.
//
// Run with:
//   flutter test integration_test/slot_state_panel_test.dart -d <device-or-sim-id>

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

  testWidgets(
      'slot panel shows the real adapter state and survives destroy/reinit',
      (tester) async {
    // Tall synthetic viewport: HomePage's tile list is long enough that
    // scrollUntilVisible's default centering can still leave a target tile
    // partially clipped at the default simulator surface size (same fix as
    // safety_status_test.dart).
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Slot state panel');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Slot state panel tile');

    // Existing in the tree doesn't mean visible/hit-testable — HomePage's
    // tile list is long enough that this tile can render below the fold on
    // the default test viewport (same pattern already handled in
    // compliance_export_test.dart / safety_status_test.dart).
    await tester.scrollUntilVisibleAndSettle(tile, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    // The pushed page's AppBar title is also "Slot state panel", and the
    // previous HomePage route (with its own matching tile) stays mounted
    // underneath a MaterialPageRoute push — so two matches is expected here;
    // just confirm the AppBar copy specifically made it on screen.
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text('Slot state panel')),
        findsOneWidget);

    // Real adapter is live — provider tag + the three singleton slot cards
    // render. No "Banner" card: T65 made banner/mrec/native per-widget-
    // instance, so there's no single slot left for this panel to show.
    final adapter = AdManager().adapter;
    expect(adapter, isNotNull);
    expect(find.textContaining('Provider: ${adapter!.tag}'), findsOneWidget);
    expect(find.text('App Open'), findsOneWidget);
    expect(find.text('Interstitial'), findsOneWidget);
    expect(find.text('Rewarded'), findsOneWidget);

    // Destroy → adapter goes null, panel falls back to the "not initialised"
    // message, without crashing.
    final destroyButton = find.widgetWithText(FilledButton, 'Destroy SDK');
    await tester.scrollUntilVisibleAndSettle(destroyButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(destroyButton);

    // destroy() tears the adapter down asynchronously (timers, notifiers, then
    // the native side) before the panel rebuilds. The re-initialise step below
    // already polls for the same reason; a fixed pump here was the odd one out
    // and is the pattern that broke two other tests on the slower CI hardware.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (AdManager().adapter == null &&
          find.text('SDK not initialised yet').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(AdManager().adapter, isNull);
    expect(find.text('SDK not initialised yet'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Reinit → adapter restored, panel renders slot cards again.
    final reinitButton = find.widgetWithText(FilledButton, 'Re-initialize SDK');
    await tester.tap(reinitButton);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (AdManager().adapter != null) break;
    }

    expect(AdManager().adapter, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
