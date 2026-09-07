// Widget test for the Compliance report demo page (T23).
//
// Exercises the page standalone (no SDK init) since
// AdManager().exportComplianceReport() is null-safe pre-init — it falls
// back to an empty event log, unset consent and non-VIP state.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows placeholder before a report is generated', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ComplianceDemoPage()));

    expect(find.text('(no report generated yet)'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNothing);
  });

  testWidgets('generating a report renders JSON and the event count',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ComplianceDemoPage()));

    await tester.tap(find.text('Generate report'));
    await tester.pump();

    expect(find.text('(no report generated yet)'), findsNothing);
    expect(find.text('0 event(s) in log'), findsOneWidget);
    expect(find.textContaining('"generatedAt"'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });

  testWidgets(
      'generating a dispute kit (T144) renders all 3 signed parts as JSON',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ComplianceDemoPage()));

    // T144's export chain does real Ed25519 signing (package:cryptography),
    // which needs actual wall-clock time to complete, not just flutter_test's
    // fake-async pump loop — the tap AND a real (non-zero) delay both need
    // to happen inside runAsync for the signing work to genuinely finish
    // before the assertions below run.
    await tester.runAsync(() async {
      await tester.tap(find.text('Generate dispute kit (T144)'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.text('(no report generated yet)'), findsNothing);
    expect(find.textContaining('compliance + bypass audit trail'),
        findsOneWidget);
    expect(find.textContaining('"compliance"'), findsOneWidget);
    expect(find.textContaining('"bypassAuditTrail"'), findsOneWidget);
    expect(find.textContaining('"incidentBundle"'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });
}
