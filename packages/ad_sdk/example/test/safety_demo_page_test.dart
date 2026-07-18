// Widget test for the Safety status demo page's policy risk score (T24) and
// the Smart Monetization Arbitrator opt-in button.
//
// Exercises the page standalone (no SDK init) since
// AdManager().policyRiskScore is safe pre-init — it starts at 0.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    AdManager().disableArbitrator();
    AdManager().disableFillRateMonitor();
  });

  Future<void> pumpSafetyPage(WidgetTester tester) async {
    // The risk score card sits below several other cards in a ListView —
    // grow the viewport so it's built without needing a scroll gesture.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: SafetyDemoPage()));
  }

  testWidgets('shows the policy risk score section starting at 0',
      (tester) async {
    await pumpSafetyPage(tester);

    expect(find.textContaining('Policy risk score'), findsOneWidget);
    expect(find.text('0 / 100'), findsOneWidget);
  });

  testWidgets('Enable Smart Arbitrator button registers the arbitrator',
      (tester) async {
    await pumpSafetyPage(tester);

    expect(find.text('disabled (default)'), findsOneWidget);
    expect(AdManager().arbitrator, isNull);

    await tester
        .tap(find.text('Enable Smart Arbitrator (per-slot + guardrail)'));
    await tester.pump();

    expect(AdManager().arbitrator, isNotNull);
    expect(find.textContaining('estimatedEcpm='), findsOneWidget);
  });

  testWidgets('Enable Fill-rate Monitor button registers the monitor',
      (tester) async {
    await pumpSafetyPage(tester);

    expect(find.text('fill-rate monitor disabled (default)'), findsOneWidget);
    expect(AdManager().fillRateMonitor, isNull);

    await tester.tap(find.text('Enable Fill-rate Monitor'));
    await tester.pump();

    expect(AdManager().fillRateMonitor, isNotNull);
    expect(find.textContaining('interstitial='), findsOneWidget);
  });
}
