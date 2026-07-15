// Widget test for RevenueDemoPage (main.dart:1691).
//
// The page just wraps RevenuePanel (already covered in ad_manager_core_test)
// plus static explainer text — this test only asserts the page's own scaffold
// renders correctly pre-init, with the panel at its zero-events default.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the revenue panel at its zero-events default',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RevenueDemoPage()));
    await tester.pump();

    expect(find.text('Revenue dashboard'), findsOneWidget);
    expect(find.text('Session Revenue'), findsOneWidget);
    expect(find.text('\$0.0000'), findsOneWidget);
    expect(find.text('0 impressions'), findsOneWidget);
  });
}
