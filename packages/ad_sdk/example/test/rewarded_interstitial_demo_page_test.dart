// Widget test for RewardedInterstitialDemoPage (main.dart).
//
// Round-27 audit — showRewardedInterstitialAd() had zero test/demo coverage
// anywhere in the example app despite being a fully-supported ad surface.
// Exercises the page standalone (no SDK init, mirrors rewarded_demo_page_test
// / interstitial_demo_page_test's pattern) — coin/last-result state renders
// correctly, and tapping "Watch" with no ad ready reports (shown: false,
// earned: false) instead of throwing or granting an unearned reward.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('starts at 0 coins with no last result', (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: RewardedInterstitialDemoPage()));

    expect(find.text('Coins: 0'), findsOneWidget);
    expect(find.text('Last: —'), findsOneWidget);
  });

  testWidgets('watch button is present and tappable', (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: RewardedInterstitialDemoPage()));

    expect(
        find.widgetWithText(
            FilledButton, 'Watch rewarded interstitial for +10 coins'),
        findsOneWidget);
  });

  testWidgets(
      'tapping watch with no SDK/ad ready reports shown=false earned=false '
      'and never grants an unearned coin', (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: RewardedInterstitialDemoPage()));

    await tester.tap(find.text('Watch rewarded interstitial for +10 coins'));
    await tester.pumpAndSettle();

    expect(find.text('Coins: 0'), findsOneWidget,
        reason: 'no coin must be granted when the ad was not actually shown');
    expect(find.textContaining('shown=false'), findsOneWidget);
    expect(find.textContaining('earned=false'), findsOneWidget);
  });
}
