// T212 fix — this used to render a plain Text() the test itself wrote and
// then assert on its own hardcoded string, proving nothing about the SDK.
//
// codex review (round 1) caught two further problems with the first
// rewrite: (1) AdManager().isInitialised was false (no debugConfig set),
// so BannerAdWidget._initBanner bailed out before ever creating a slot —
// bannerSlots.length stayed 0 even if disposal were completely broken;
// (2) the route-transition dimension the task asked for was dropped
// entirely. This version fixes both: real AdConfig via debugConfig so
// banners actually mount, and a real Navigator + AdScreenRouteLogger doing
// real push/pop cycles instead of just swapping pumpWidget's tree.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  testWidgets(
      'a real Navigator push/pop storm mounting/unmounting BannerAdWidget '
      'leaves no tracked banner slots behind, and the route observer '
      'genuinely saw every transition', (tester) async {
    final adapter = FakeAdProviderAdapter();
    AdManager().debugConfig = _config;
    AdManager().debugSetAdapter(adapter);
    AdManager().debugCanRequestAds = true;
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });
    AdScreenRouteLogger.resetState();

    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [AdScreenRouteLogger()],
      home: const Scaffold(body: Text('home')),
    ));
    // Captured AFTER the initial mount's own didPush(home) has already
    // fired, so only the storm's own push/pop pairs below are counted.
    final observedBefore = AdScreenRouteLogger.navigationEventsObserved;

    const storms = 20;
    for (var i = 0; i < storms; i++) {
      navigatorKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: BannerAdWidget()),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(BannerAdWidget), findsOneWidget,
          reason: 'sanity — the pushed screen must actually be showing '
              'before popping back, or this storm proves nothing');

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
    }

    expect(
      AdScreenRouteLogger.navigationEventsObserved - observedBefore,
      storms * 2,
      reason: 'T212 — the real route observer must have seen every one '
          'of these push+pop cycles, not just the widget tree churning '
          'independently of it',
    );
    expect(adapter.bannerSlots.length, 0,
        reason: 'T212 — every banner instance from the push/pop storm '
            'above must have been disposed when its route popped; none '
            'should still be tracked once the storm ends');
  });
}
