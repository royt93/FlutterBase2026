// MJ20 + M3 + MJ21 (2026-08-22 audit): banner/mrec/native depend entirely on
// GMA calling a listener back — unlike the four fullscreen formats, they had
// no load watchdog of their own, so a listener that never fired left the
// slot `loading` forever (M3: even fixing the slot state alone isn't enough
// — the adapter also caches the dead ad object per key and early-returns on
// it, so the cache must be dropped too). MJ21 covers a different race: the
// banner path suspends on a real platform call (adaptive-size lookup) before
// creating its ad, and a widget disposed mid-await must not resurrect a
// BannerAd for a key nobody owns any more.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// AdMessageCodec isn't exported from the public API — same workaround as
// gma_bridge_test.dart / admob_adapter_test.dart.
import 'package:google_mobile_ads/src/ad_instance_manager.dart' show AdMessageCodec;

import 'admob_behavioral_test.dart' show FakeGmaBridge;

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
    mrecId: 'm',
    nativeId: 'n',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AdMobAdapter adapter;

  setUp(() async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(_config), isTrue);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('MJ20 + M3 — widget load watchdog', () {
    test(
        'mrec: a GMA listener that never calls back must not strand the slot '
        'in loading forever', () {
      fakeAsync((async) {
        adapter.loadMrecIfNeeded('k', 300);
        async.flushMicrotasks();
        expect(adapter.debugMrecListenerFor('k'), isNotNull,
            reason: 'a real BannerAd must be pending, waiting on GMA');
        expect(adapter.mrecSlot('k').isLoading, isTrue);

        async.elapse(const Duration(seconds: 31));

        expect(adapter.mrecSlot('k').isLoading, isFalse,
            reason: 'MJ20: the watchdog must move the slot out of loading');
        expect(adapter.mrec('k').hasError.value, isTrue);
        expect(adapter.debugMrecListenerFor('k'), isNull,
            reason: 'M3: the dead BannerAd must be dropped from the cache, '
                'not just the slot state — otherwise the next '
                'loadMrecIfNeeded early-returns on the stale cache entry');
      });
    });

    test(
        'native: a GMA listener that never calls back must not strand the '
        'slot in loading forever', () {
      fakeAsync((async) {
        adapter.preloadNative('k');
        async.flushMicrotasks();
        expect(adapter.debugNativeListenerFor('k'), isNotNull);
        expect(adapter.nativeSlot('k').isLoading, isTrue);

        async.elapse(const Duration(seconds: 31));

        expect(adapter.nativeSlot('k').isLoading, isFalse,
            reason: 'MJ20: the watchdog must move the slot out of loading');
        // T152 — native's watchdog was missing this call (banner/mrec
        // above both have it): without markError(), needsRecovery (only
        // set inside markError()) never flips, so onAppResumed()'s native
        // mirror never retries — the widget can be stuck on its shimmer
        // placeholder forever, with hasError staying false, instead of
        // showing an error state or self-healing on resume.
        expect(adapter.native('k').hasError.value, isTrue);
        expect(adapter.debugNativeListenerFor('k'), isNull,
            reason: 'M3: the dead NativeAd must be dropped from the cache');
        // T152 — the actual end-to-end claim: needsRecovery is what
        // onAppResumed()'s native mirror checks before retrying (see
        // admob_resume_recovery_test.dart for the same pattern on a
        // real onAdFailedToLoad callback instead of a watchdog timeout).
        expect(adapter.native('k').needsRecovery, isTrue);

        // Clear the failure backoff so the resume retry isn't refused by
        // it, then prove the resume mirror actually fires a new request.
        adapter.nativeSlot('k').lastErrorAt =
            DateTime.now().subtract(const Duration(seconds: 20));
        adapter.onAppResumed();
        async.flushMicrotasks();

        expect(adapter.debugNativeListenerFor('k'), isNotNull,
            reason: 'T152 — resume must self-heal a watchdog-timed-out '
                'native slot, same as it already does for banner/mrec');
      });
    });

    test(
        'banner: a GMA listener that never calls back must not strand the '
        'slot in loading forever', () {
      fakeAsync((async) {
        adapter.loadBannerIfNeeded('k', 300);
        // Let the adaptive-size platform call (mocked to return null) resolve
        // so the real BannerAd gets created, same as production.
        async.elapse(const Duration(seconds: 1));
        expect(adapter.debugBannerListenerFor('k'), isNotNull);
        expect(adapter.bannerSlot('k').isLoading, isTrue);

        async.elapse(const Duration(seconds: 31));

        expect(adapter.bannerSlot('k').isLoading, isFalse,
            reason: 'MJ20: the watchdog must move the slot out of loading');
        expect(adapter.banner('k').hasError.value, isTrue);
        expect(adapter.debugBannerListenerFor('k'), isNull,
            reason: 'M3: the dead BannerAd must be dropped from the cache');
      });
    });
  });

  group('MJ21 — dispose-during-await race', () {
    test(
        'banner disposed while the adaptive-size lookup is in flight must '
        'not resurrect a BannerAd for the abandoned key', () async {
      final sizeLookup = Completer<num?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'AdSize#getAnchoredAdaptiveBannerAdSize') {
          return sizeLookup.future;
        }
        return null;
      });

      final loadFuture = adapter.loadBannerIfNeeded('k', 300);
      // Pump one microtask turn so loadBannerIfNeeded reaches the await.
      await Future<void>.delayed(Duration.zero);
      expect(adapter.bannerSlot('k').isLoading, isTrue,
          reason: 'sanity: the load must be in flight, suspended on the '
              'platform call, before the widget goes away');

      // Widget torn down mid-load (fast scroll away). Same key would be
      // reused by a freshly-mounted widget with a brand-new AdSlot, so an
      // identity check (not a per-key tombstone) is what must catch this.
      adapter.disposeBannerInstance('k');
      sizeLookup.complete(50);
      await loadFuture;

      expect(adapter.debugBannerListenerFor('k'), isNull,
          reason: 'a load nobody owns any more must not create a BannerAd');
    });
  });
}
