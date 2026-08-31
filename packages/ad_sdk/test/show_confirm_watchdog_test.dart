// Round-7 audit, MAJOR — a full-screen slot stuck in `showing` forever.
//
// `showX()` hands the request to a fire-and-forget native call and then waits
// for a callback. When the native SDK swallows the request entirely — AppLovin
// `showAd()` on an ad its own cache has since dropped is a documented no-op,
// and a GMA ad whose presenting activity dies is the same class of failure —
// no callback of ANY kind arrives. The slot then sits in `showing` for the rest
// of the session: `beginLoad()` and `beginReload()` both refuse while
// `isShowing`, so that format never loads again, and the caller awaiting the
// show result never resolves either. One wedged interstitial meant zero
// interstitials until the user restarted the app.
//
// `AdSlot.beginShow(onShowNeverConfirmed: ...)` watches only the gap between
// "we asked" and "the SDK says it is on screen" — `markDisplayed()` closes it.
// The last group pins that boundary down, because a watchdog that could fire
// on a legitimately-displayed ad would be worse than the hang: it would tear
// down a live ad and let a second full-screen stack on top of it.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge;
import 'applovin_adapter_test.dart' show FakeAppLovinBridge;

const _alConfig = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'key',
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
    rewardedInterstitialId: 'ri',
  ),
);

MaxAd _fakeAd() => MaxAd('unit', 'INTER', null, 'net', '', 0.0, 'exact', 'cid',
    'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0), null, null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdSlot.beginShow watchdog', () {
    test('a show the SDK never confirms releases the slot and the caller', () {
      fakeAsync((async) {
        final slot = AdSlot(type: AdSlotType.interstitial);
        addTearDown(slot.dispose);
        slot.markReady();

        var released = 0;
        expect(slot.beginShow(onShowNeverConfirmed: () => released++), isTrue);

        async.elapse(AdSlot.showConfirmTimeout - const Duration(seconds: 1));
        expect(slot.isShowing, isTrue, reason: 'must not fire early');
        expect(released, 0);

        async.elapse(const Duration(seconds: 2));
        expect(released, 1, reason: 'the adapter must get to release its ad '
            'object and resolve the awaiting caller');
        expect(slot.isShowing, isFalse);
        expect(slot.beginLoad(backoff: const Backoff(baseMs: 0)), isTrue,
            reason: 'THE POINT: the format can load again. While the slot was '
                'stuck `showing`, every later beginLoad/beginReload refused');
      });
    });

    test('markDisplayed disarms it — a long-running ad is never torn down', () {
      fakeAsync((async) {
        final slot = AdSlot(type: AdSlotType.rewarded);
        addTearDown(slot.dispose);
        slot.markReady();

        var released = 0;
        slot.beginShow(onShowNeverConfirmed: () => released++);
        slot.markDisplayed();

        // A rewarded ad the user pauses, or an iOS ad still presented while
        // the app sits in the background after a click-out to the App Store.
        async.elapse(const Duration(minutes: 30));
        expect(released, 0);
        expect(slot.isShowing, isTrue,
            reason: 'the ad is on screen — releasing the slot here would let a '
                'second full-screen stack on top of it');
      });
    });

    test('a normal dismiss cancels it', () {
      fakeAsync((async) {
        final slot = AdSlot(type: AdSlotType.interstitial);
        addTearDown(slot.dispose);
        slot.markReady();
        var released = 0;
        slot.beginShow(onShowNeverConfirmed: () => released++);
        slot.markDismissed();
        async.elapse(const Duration(minutes: 1));
        expect(released, 0);
      });
    });

    test('reset() also cancels the load watchdog', () {
      fakeAsync((async) {
        final slot = AdSlot(type: AdSlotType.banner);
        addTearDown(slot.dispose);
        slot.beginLoad();
        slot.armLoadWatchdog('banner', const Duration(seconds: 30));
        slot.reset();
        // A fresh load window the stale watchdog must not poison.
        slot.beginLoad();
        async.elapse(const Duration(seconds: 31));
        expect(slot.isLoading, isTrue,
            reason: 'the cancelled watchdog belonged to the previous load; '
                'firing markFailed() here would stamp lastErrorAt and arm a '
                'backoff against a load that never failed');
      });
    });
  });

  group('AppLovin: a swallowed show does not wedge the slot', () {
    late FakeAppLovinBridge bridge;
    late AppLovinAdapter adapter;

    setUp(() async {
      bridge = FakeAppLovinBridge();
      adapter = AppLovinAdapter(bridge: bridge);
      await adapter.initialize(_alConfig);
    });

    tearDown(() => adapter.dispose());

    test('interstitial', () {
      fakeAsync((async) {
        adapter.loadInterstitial();
        async.flushMicrotasks();
        bridge.inter!.onAdLoadedCallback(_fakeAd());

        bool? done;
        adapter.showInterstitial(onDone: (d) => done = d);
        async.flushMicrotasks();
        expect(adapter.interstitialSlot.isShowing, isTrue);
        expect(bridge.showInterCalls, hasLength(1));

        // AppLovin logs an error natively and fires nothing at all.
        async.elapse(const Duration(seconds: 11));

        expect(done, isFalse,
            reason: 'the awaiting caller (a level-complete transition) would '
                'otherwise hang forever');
        expect(adapter.interstitialSlot.isShowing, isFalse);
      });
    });

    test('interstitial: the displayed callback disarms it', () {
      fakeAsync((async) {
        adapter.loadInterstitial();
        async.flushMicrotasks();
        bridge.inter!.onAdLoadedCallback(_fakeAd());
        bool? done;
        adapter.showInterstitial(onDone: (d) => done = d);
        async.flushMicrotasks();

        bridge.inter!.onAdDisplayedCallback(_fakeAd());
        async.elapse(const Duration(minutes: 5));

        expect(done, isNull, reason: 'the ad is on screen — the caller must '
            'still be waiting for a real dismiss');
        expect(adapter.interstitialSlot.isShowing, isTrue);
      });
    });

    test('rewarded', () {
      fakeAsync((async) {
        adapter.loadRewarded();
        async.flushMicrotasks();
        bridge.rewarded!.onAdLoadedCallback(_fakeAd());

        RewardResult? result;
        adapter.showRewarded(onDone: (r) => result = r);
        async.flushMicrotasks();
        expect(adapter.rewardedSlot.isShowing, isTrue);

        async.elapse(const Duration(seconds: 11));

        expect(result?.earned, isFalse,
            reason: 'a reward request that never resolves leaves the host UI '
                'spinning on its "watch ad" button forever');
        expect(adapter.rewardedSlot.isShowing, isFalse);
      });
    });

    test('rewarded: the displayed callback disarms it', () {
      fakeAsync((async) {
        adapter.loadRewarded();
        async.flushMicrotasks();
        bridge.rewarded!.onAdLoadedCallback(_fakeAd());
        RewardResult? result;
        adapter.showRewarded(onDone: (r) => result = r);
        async.flushMicrotasks();

        bridge.rewarded!.onAdDisplayedCallback(_fakeAd());
        async.elapse(const Duration(minutes: 5));

        expect(result, isNull);
        expect(adapter.rewardedSlot.isShowing, isTrue);
      });
    });
  });

  group('AdMob: a swallowed show does not wedge the slot', () {
    late FakeGmaBridge bridge;
    late AdMobAdapter adapter;

    setUp(() async {
      bridge = FakeGmaBridge();
      adapter = AdMobAdapter(bridge: bridge);
      await adapter.initialize(_admobConfig);
    });

    tearDown(() => adapter.dispose());

    test('interstitial', () {
      fakeAsync((async) {
        unawaited(adapter.loadInterstitial());
        async.flushMicrotasks();
        // `hangOnShow` captures the callbacks and never resolves — exactly a
        // presentation that dies without reporting anything back.
        final ad = bridge.lastInter!..hangOnShow = true;

        bool? done;
        unawaited(adapter.showInterstitial(onDone: (d) => done = d));
        async.flushMicrotasks();
        expect(adapter.interstitialSlot.isShowing, isTrue);

        async.elapse(const Duration(seconds: 11));

        expect(done, isFalse);
        expect(adapter.interstitialSlot.isShowing, isFalse);
        expect(ad.disposeCount, 1,
            reason: 'the abandoned native ad would otherwise leak for the '
                'rest of the session');
      });
    });

    test('interstitial: onShowed disarms it', () {
      fakeAsync((async) {
        unawaited(adapter.loadInterstitial());
        async.flushMicrotasks();
        final ad = bridge.lastInter!..hangOnShow = true;
        bool? done;
        unawaited(adapter.showInterstitial(onDone: (d) => done = d));
        async.flushMicrotasks();

        ad.shown!.onShowed!();
        async.elapse(const Duration(minutes: 5));

        expect(done, isNull);
        expect(adapter.interstitialSlot.isShowing, isTrue);
        expect(ad.disposeCount, 0);
      });
    });

    test('rewarded', () {
      fakeAsync((async) {
        unawaited(adapter.loadRewarded());
        async.flushMicrotasks();
        final ad = bridge.lastRewarded!..hangOnShow = true;

        RewardResult? result;
        unawaited(adapter.showRewarded(onDone: (r) => result = r));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 11));

        expect(result?.earned, isFalse);
        expect(adapter.rewardedSlot.isShowing, isFalse);
        expect(ad.disposeCount, 1);
      });
    });

    test('rewarded interstitial', () {
      fakeAsync((async) {
        unawaited(adapter.loadRewardedInterstitial());
        async.flushMicrotasks();
        final ad = bridge.lastRewardedInterstitial!..hangOnShow = true;

        RewardResult? result;
        unawaited(adapter.showRewardedInterstitial(onDone: (r) => result = r));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 11));

        expect(result?.earned, isFalse);
        expect(adapter.rewardedInterstitialSlot.isShowing, isFalse);
        expect(ad.disposeCount, 1);
      });
    });
  });
}
