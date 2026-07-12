// On-device integration test for the Compliance Report export (T23).
//
// Boots the full example app, waits for SDK init, then exercises
// AdManager().exportComplianceReport() both directly and through the
// ComplianceDemoPage UI to prove the whole flow works against the real
// native SDK (not just the null-safe pre-init path already covered by the
// headless widget test).
//
// Run with:
//   flutter test integration_test/compliance_export_test.dart -d <device-or-sim-id>

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

  testWidgets('exportComplianceReport returns a well-formed report post-init',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final report = AdManager().exportComplianceReport();

    expect(
        report.generatedAt
            .isBefore(DateTime.now().toUtc().add(const Duration(minutes: 1))),
        isTrue);
    expect(report.vipActive, AdManager().isVIPMember());
    expect(report.safety.maxFullscreenAdsPerSession, greaterThan(0));
    expect(() => report.toJsonString(pretty: true), returnsNormally);
    expect(report.toJsonString(), contains('"generatedAt"'));
  });

  testWidgets('Compliance report demo page generates a report on-device',
      (tester) async {
    // Tall synthetic viewport: HomePage's ListView is a lazy Sliver under the
    // hood, so "Compliance report" (the LAST tile) never gets an Element at
    // all — not just "off-screen" — until something scrolls it into the
    // build/cache extent. find.text()/evaluate() only sees built Elements, so
    // the plain poll loop below can never find it without this (same fix
    // already applied in slot_state_panel_test.dart / safety_status_test.dart).
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Compliance report');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Compliance report tile');

    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text('Compliance report')),
        findsOneWidget,
        reason: 'tap must have navigated into ComplianceDemoPage');

    // Not find.widgetWithText(FilledButton, ...): FilledButton.icon(...) is a
    // factory returning the private subclass _FilledButtonWithIcon, whose
    // runtimeType never equals FilledButton — widgetWithText/byType do an
    // exact runtimeType match, so they silently find nothing for .icon
    // buttons. byWidgetPredicate's `is FilledButton` check matches the
    // subclass correctly.
    final generateButton = find.ancestor(
      of: find.text('Generate report'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    expect(generateButton, findsOneWidget);
    await tester.tap(generateButton);
    await tester.pump();

    expect(find.text('(no report generated yet)'), findsNothing);
    expect(find.textContaining('event(s) in log'), findsOneWidget);
    expect(find.textContaining('"generatedAt"'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
