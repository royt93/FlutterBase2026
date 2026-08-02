// On-device integration test for the consent-country control (T27) on the
// Consent / GDPR demo page (ConsentDemoPage) — distinct from
// consent_dialog_test.dart, which only exercises the GDPR/COPPA/CCPA
// switches + "Apply consent to providers" button and never touches the
// country field.
//
// Typing a country and tapping "Set" calls the real
// `ConsentManager.instance.set(...)` and the card above re-renders from
// `ConsentManager.instance.listenable` — this test asserts that real state
// round-trip, not just local TextField contents.
//
// Run with:
//   flutter test integration_test/consent_country_demo_test.dart -d <device-or-sim-id>

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
      'setting a consent country reaches ConsentManager and re-renders the card',
      (tester) async {
    // HomePage's demo list is a viewport-lazy ListView — "Consent / GDPR"
    // isn't built at all at default phone height (see compliance_export_test.dart
    // for the same issue). Use a tall synthetic viewport instead of requiring
    // a real scroll gesture to find the tile.
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Consent / GDPR');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Consent / GDPR tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Consent demo'), findsOneWidget);

    // ConsentDemoPage is a fresh full-screen route — restore the real device
    // viewport before hit-testing it (see log_viewer_test.dart for why the
    // synthetic size can't be trusted for a route mounted after it's set).
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();

    final countryField =
        find.widgetWithText(TextField, 'Consent country (e.g. DE, US)');
    await tester.scrollUntilVisible(countryField, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(countryField, 'DE');
    await tester.pump();

    // Two things move "Set" out from under the pointer between the moment a
    // finder reads its rect and the moment the pointer is dispatched, and both
    // produced "derived an Offset that would not hit test" with a null country
    // afterwards:
    //   • entering text opens the real keyboard, so the Scaffold resizes for
    //     viewInsets.bottom (measured 0 -> 288 on the iOS Simulator);
    //   • scrollUntilVisible drags in steps and leaves a ballistic
    //     BouncingScrollPhysics animation still running afterwards.
    // Dismissing the keyboard only fixes the first, and on the CI simulator the
    // keyboard never appears at all (viewInsets stays 0) — so that run failed on
    // the second cause while a local run, on much faster hardware where the
    // fling had already settled, passed.
    //
    // Rather than enumerate every source of movement, wait until the button's
    // rect stops changing. That covers both causes and any future one.
    FocusManager.instance.primaryFocus?.unfocus();

    final setButton = find.widgetWithText(FilledButton, 'Set');
    await tester.scrollUntilVisible(setButton, 200,
        scrollable: find.byType(Scrollable).first);

    Rect? previous;
    var stableFrames = 0;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final current = tester.getRect(setButton);
      stableFrames = current == previous ? stableFrames + 1 : 0;
      previous = current;
      // Three identical frames in a row: layout has settled, not merely paused
      // between two drag steps of an easing curve.
      if (stableFrames >= 3) break;
    }
    expect(stableFrames >= 3, isTrue,
        reason: 'the Set button never stopped moving, so a tap would race it');

    await tester.tap(setButton);

    // Everything this test asserts lands asynchronously and at different
    // speeds per platform: ConsentManager.set() persists through a real
    // platform channel before its listenable fans out (measured: already
    // applied on the next frame on Android, ~300-600ms on the iOS Simulator),
    // and the confirmation SnackBar is not built until a frame after the tap.
    // A single fixed pump therefore raced a different assertion on each
    // platform. Poll for all three observable effects instead, capped below
    // the SnackBar's ~4s auto-dismiss so waiting cannot outlive what we assert.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final applied = ConsentManager.instance.current.country == 'DE';
      final announced = find
          .textContaining('Consent country set to DE')
          .evaluate()
          .isNotEmpty;
      final rerendered =
          find.textContaining('country=DE').evaluate().isNotEmpty;
      if (applied && announced && rerendered) break;
    }

    // Applied state must reach the real ConsentManager singleton.
    expect(ConsentManager.instance.current.country, 'DE');
    expect(find.textContaining('Consent country set to DE'), findsOneWidget);
    // The card above re-renders from the same listenable — assert it now
    // shows the applied country instead of the "(not set...)" placeholder.
    expect(find.textContaining('country=DE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
