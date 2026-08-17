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
      mgr.recordBannerLoad('k');
      expect(mgr.canLoadBanner('k'), isFalse,
          reason: 'within the cooldown window after a load');
    });
  });

  // 2026-08-16 audit: destroy() only cleared the banner cooldown map, missing
  // mrec/native (all 3 added together at T65) — a destroy() + fresh
  // initialize() within the cooldown window (without unmounting the widget)
  // would leave MREC/Native inconsistently "still on cooldown" vs Banner.
  group('destroy() clears every per-widget-key cooldown map (2026-08-16 audit)',
      () {
    test('banner/mrec/native cooldowns are all cleared by destroy()',
        () async {
      mgr.recordBannerLoad('k');
      mgr.recordMrecLoad('k');
      mgr.recordNativeLoad('k');
      expect(mgr.canLoadBanner('k'), isFalse);
      expect(mgr.canLoadMrec('k'), isFalse);
      expect(mgr.canLoadNative('k'), isFalse);

      await mgr.destroy();

      expect(mgr.canLoadBanner('k'), isTrue);
      expect(mgr.canLoadMrec('k'), isTrue,
          reason: 'mrec cooldown must be cleared by destroy() same as banner');
      expect(mgr.canLoadNative('k'), isTrue,
          reason:
              'native cooldown must be cleared by destroy() same as banner');
    });
  });

  group('splash counters', () {
    test('incrementSplashCount increases countInitSplashScreen by exactly 1',
        () {
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
