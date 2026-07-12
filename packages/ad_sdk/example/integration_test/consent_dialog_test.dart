// On-device integration test for the Consent / GDPR demo (ConsentDemoPage).
//
// Boots the full example app, navigates to the Consent demo, and verifies
// the consent flags UI renders and that toggling the visible switches and
// tapping "Apply consent to providers" actually reaches
// `AdManager().consent` (the real consent state read by both native
// adapters), not just local widget state.
//
// Run with:
//   flutter test integration_test/consent_dialog_test.dart -d <device-or-sim-id>

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
      'toggling consent switches + Apply propagates into AdManager().consent',
      (tester) async {
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

    // The three switches from ConsentDemoPage._row(...).
    expect(find.text('GDPR consent (hasUserConsent)'), findsOneWidget);
    expect(find.text('Age-restricted (COPPA)'), findsOneWidget);
    expect(find.text('Do-not-sell (CCPA)'), findsOneWidget);

    final gdprSwitch =
        find.widgetWithText(SwitchListTile, 'GDPR consent (hasUserConsent)');
    await tester.tap(gdprSwitch);
    await tester.pump();

    final applyButton =
        find.widgetWithText(FilledButton, 'Apply consent to providers');
    await tester.scrollUntilVisible(applyButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(applyButton);
    await tester.pump(const Duration(milliseconds: 300));

    // Applied state must reach the real AdManager().consent surface.
    expect(AdManager().consent.hasUserConsent, isTrue);
    expect(find.textContaining('Consent applied to both providers'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
