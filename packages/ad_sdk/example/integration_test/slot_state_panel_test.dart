// On-device integration test for the Slot state panel demo
// (StatePanelDemoPage).
//
// Asserts the live AdSlot state panel renders the real adapter's four slots
// (App Open / Interstitial / Rewarded / Banner) and that the manual
// destroy/reinit controls actually reach `AdManager()` — destroy nulls the
// adapter (panel falls back to "SDK not initialised yet"), reinit restores it
// — without crashing.
//
// Run with:
//   flutter test integration_test/slot_state_panel_test.dart -d <device-or-sim-id>

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
    await tester.scrollUntilVisible(tile, 200,
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

    // Real adapter is live — provider tag + all four slot cards render.
    final adapter = AdManager().adapter;
    expect(adapter, isNotNull);
    expect(find.textContaining('Provider: ${adapter!.tag}'), findsOneWidget);
    expect(find.text('App Open'), findsOneWidget);
    expect(find.text('Interstitial'), findsOneWidget);
    expect(find.text('Rewarded'), findsOneWidget);
    expect(find.text('Banner'), findsOneWidget);

    // Destroy → adapter goes null, panel falls back to the "not initialised"
    // message, without crashing.
    final destroyButton = find.widgetWithText(FilledButton, 'Destroy SDK');
    await tester.scrollUntilVisible(destroyButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(destroyButton);
    await tester.pump(const Duration(milliseconds: 300));

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
