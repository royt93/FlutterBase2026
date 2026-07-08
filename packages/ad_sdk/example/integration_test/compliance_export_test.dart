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
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Compliance report');
    var foundTile = false;
    for (var i = 0; i < 20; i++) {
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final generateButton = find.widgetWithText(FilledButton, 'Generate report');
    expect(generateButton, findsOneWidget);
    await tester.tap(generateButton);
    await tester.pump();

    expect(find.text('(no report generated yet)'), findsNothing);
    expect(find.textContaining('event(s) in log'), findsOneWidget);
    expect(find.textContaining('"generatedAt"'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
