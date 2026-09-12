import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('fallback status is readable in a privacy status widget',
      (tester) async {
    final state = ConsentFallbackState.create(
      policyRevision: 'ump-v1',
      reason: ConsentFallbackReason.timeout,
    );
    await tester.pumpWidget(MaterialApp(
      home: Text('Consent fallback: ${state.reason.name} · conservative'),
    ));
    expect(find.textContaining('timeout'), findsOneWidget);
    expect(find.textContaining('conservative'), findsOneWidget);
  });
}
