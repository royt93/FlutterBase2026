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
}
