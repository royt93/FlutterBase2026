// Tests for the AdManager orchestrator's behaviour BEFORE/ WITHOUT a provider
// adapter (the SDK is a singleton whose adapters need the native plugins, which
// aren't reachable in a unit test). These lock down the safe-default contract:
// every entry point must short-circuit gracefully (no crash, callbacks fired
// with a safe value) when the SDK hasn't been initialised — exactly the state a
// host hits if it calls an ad API before `initialize()`.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mgr = AdManager();

  test('singleton: AdManager() always returns the same instance', () {
    expect(identical(AdManager(), mgr), isTrue);
  });

  group('uninitialised state', () {
    test('isInitialised is false and vip is null before initialize()', () {
      expect(mgr.isInitialised, isFalse);
      expect(mgr.vip, isNull);
    });

    test('isVIPMember defaults to false', () {
      expect(mgr.isVIPMember(), isFalse);
    });

    test('canShowInterstitial / canShowRewardedAd are false (no adapter)', () {
      expect(mgr.canShowInterstitial(), isFalse);
      expect(mgr.canShowRewardedAd(), isFalse);
    });

    test('events exposes a broadcast stream', () {
      expect(mgr.events.isBroadcast, isTrue);
    });
  });

  group('show/load short-circuit safely without an adapter', () {
    test('showInterstitial fires onDoneFlow(false)', () async {
      bool? shown;
      await mgr.showInterstitial(onDoneFlow: (s) => shown = s);
      expect(shown, isFalse);
    });

    test('showRewardedAd fires onEarnedReward(false)', () async {
      bool? earned;
      await mgr.showRewardedAd(onEarnedReward: (e) => earned = e);
      expect(earned, isFalse);
    });

    test('loadAppOpenAd fires onAdLoaded(false)', () async {
      bool? loaded;
      await mgr.loadAppOpenAd(onAdLoaded: (l) => loaded = l);
      expect(loaded, isFalse);
    });

    test('loadInterstitial / loadRewardedAd do not throw', () async {
      await expectLater(mgr.loadInterstitial(), completes);
      await expectLater(mgr.loadRewardedAd(), completes);
    });
  });

  group('banner load cooldown', () {
    test('canLoadBanner is false immediately after recordBannerLoad', () {
      mgr.recordBannerLoad();
      expect(mgr.canLoadBanner(), isFalse,
          reason: 'within the cooldown window after a load');
    });
  });

  group('splash counters', () {
    test('incrementSplashCount increases countInitSplashScreen by exactly 1', () {
      final before = mgr.countInitSplashScreen;
      mgr.incrementSplashCount();
      expect(mgr.countInitSplashScreen, before + 1);
    });

    test('markSplashActive / markSplashInactive do not throw', () {
      expect(() {
        mgr.markSplashActive();
        mgr.markSplashInactive();
      }, returnsNormally);
    });
  });
}
