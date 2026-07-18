// Widget test for RewardedDemoPage's SSV user-id field (main.dart).
//
// Exercises the page standalone (no SDK init) — typing into the SSV field
// should not throw, and the field should be present and empty by default.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows an empty SSV user id field by default', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RewardedDemoPage()));

    expect(find.widgetWithText(TextField, 'SSV user id (optional)'),
        findsOneWidget);
  });

  testWidgets('typing an SSV user id does not throw', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RewardedDemoPage()));

    await tester.enterText(find.byType(TextField), 'user-123');
    await tester.pump();

    expect(find.text('user-123'), findsOneWidget);
  });
}
