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

    // Entering text just opened the real software keyboard (iOS Simulator
    // always shows one; the Android CI emulator has it disabled, which is why
    // this only broke there). The Scaffold resizes for viewInsets.bottom,
    // which can push "Set" out of the region we already scrolled into view
    // for countryField — re-scroll it back before tapping.
    final setButton = find.widgetWithText(FilledButton, 'Set');
    await tester.scrollUntilVisible(setButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(setButton);
    await tester.pump(const Duration(milliseconds: 300));

    // Applied state must reach the real ConsentManager singleton.
    expect(ConsentManager.instance.current.country, 'DE');
    expect(find.textContaining('Consent country set to DE'), findsOneWidget);
    // The card above re-renders from the same listenable — assert it now
    // shows the applied country instead of the "(not set...)" placeholder.
    expect(find.textContaining('country=DE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
