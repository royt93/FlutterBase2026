// Widget test for the Safety status demo page's policy risk score (T24).
//
// Exercises the page standalone (no SDK init) since
// AdManager().policyRiskScore is safe pre-init — it starts at 0.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the policy risk score section starting at 0',
      (tester) async {
    // The risk score card sits below several other cards in a ListView —
    // grow the viewport so it's built without needing a scroll gesture.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: SafetyDemoPage()));

    expect(find.textContaining('Policy risk score'), findsOneWidget);
    expect(find.text('0 / 100'), findsOneWidget);
  });
}
