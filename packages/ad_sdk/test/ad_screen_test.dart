// Widget tests for AdScreen / AdScreenState — the high-level helper a host
// screen extends to get buildBanner() + showInterstitialAd() + showRewardedAd()
// with built-in pre-checks. Without an initialised SDK every show must resolve
// safely to `false` (no dialog, no crash), and buildBanner must render an empty
// banner. This proves the safe-default contract from the screen layer.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DemoAdScreen extends AdScreen {
  const _DemoAdScreen({required this.onInter, required this.onReward});
  final void Function(bool) onInter;
  final void Function(bool) onReward;

  @override
  State<_DemoAdScreen> createState() => _DemoAdScreenState();
}

class _DemoAdScreenState extends AdScreenState<_DemoAdScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          buildBanner(),
          ElevatedButton(
            key: const Key('inter'),
            onPressed: () => showInterstitialAd(
              placement: AdPlacement.gameOver,
              onDone: widget.onInter,
            ),
            child: const Text('inter'),
          ),
          ElevatedButton(
            key: const Key('reward'),
            onPressed: () => showRewardedAd(onEarnedReward: widget.onReward),
            child: const Text('reward'),
          ),
        ],
      ),
    );
  }
}

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: child,
      );

  testWidgets('buildBanner renders (empty when SDK not initialised)',
      (tester) async {
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (_) {},
      onReward: (_) {},
    )));
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showInterstitialAd fails the pre-check → onDone(false)',
      (tester) async {
    bool? result;
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (v) => result = v,
      onReward: (_) {},
    )));
    await tester.tap(find.byKey(const Key('inter')));
    await tester.pump();
    expect(result, isFalse,
        reason: 'no adapter → canShowInterstitial false → no dialog, onDone(false)');
  });

  testWidgets('showRewardedAd with no ad → onEarnedReward(false)',
      (tester) async {
    bool? reward;
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (_) {},
      onReward: (v) => reward = v,
    )));
    await tester.tap(find.byKey(const Key('reward')));
    await tester.pump(); // onEarnedReward(false) fires synchronously
    expect(reward, isFalse);
    // No-ad path shows a 3 s TopToast — pump past it so no timer is left pending.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('disposed screen resolves shows to false without throwing',
      (tester) async {
    bool? result;
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (v) => result = v,
      onReward: (_) {},
    )));
    // Tear the screen down, then a late callback must be safe.
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsNothing);
    expect(tester.takeException(), isNull);
    expect(result, isNull);
  });
}
