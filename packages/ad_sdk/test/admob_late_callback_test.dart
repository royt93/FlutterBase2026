// M4 (round-6 audit) — the widget-format load listeners capture `listenables`
// and `slot` as locals. The MJ21/B-2 identity guard covers only the `await`
// window BEFORE the ad is created; after `..load()` there is a much longer
// window — until the native fill lands — during which a fast scroll or a route
// pop runs disposeXInstance(key) and disposes exactly those notifiers.
//
// The callback then writes to a disposed ValueNotifier. In debug/profile that
// throws out of the plugin's method-channel handler; release is benign because
// the asserts are compiled out. So this is a developer-facing crash rather than
// a store crash — but it is 6 call sites (onAdLoaded + onAdFailedToLoad across
// banner, MREC and native) where the family fix was applied to one half only.
//
// These drive the REAL listeners the production load path created, via the
// existing debug seams — not re-implemented copies — so reverting a guard makes
// the matching test fail for real.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;

import 'admob_behavioral_test.dart' show FakeGmaBridge;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = AdConfig(
    provider: AdProvider.admob,
    admob: AdMobConfig(
      bannerId: 'b',
      interstitialId: 'i',
      appOpenId: 'ao',
      mrecId: 'm',
      nativeId: 'n',
    ),
  );

  // The banner path (unlike MREC/native) asks the platform for an adaptive
  // size before it creates the ad, and returns early if that comes back null —
  // which is why an unstubbed channel leaves no listener to drive.
  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAnchoredAdaptiveBannerAdSize') {
        return AdSize.banner;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  BannerAd dummyBanner() => BannerAd(
        adUnitId: 'b',
        size: AdSize.banner,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );

  Future<AdMobAdapter> newAdapter() async {
    final adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(config), isTrue);
    addTearDown(adapter.dispose);
    return adapter;
  }

  group('a callback arriving after disposeXInstance must be dropped', () {
    test('banner onAdLoaded', () async {
      final adapter = await newAdapter();
      await adapter.loadBannerIfNeeded('k', 320);
      final listener = adapter.debugBannerListenerFor('k');
      expect(listener, isNotNull);

      adapter.disposeBannerInstance('k');

      expect(() => listener!.onAdLoaded!(dummyBanner()), returnsNormally,
          reason: 'the widget is gone and its notifiers are disposed; a late '
              'fill must be dropped, not written through');
    });

    test('banner onAdFailedToLoad', () async {
      final adapter = await newAdapter();
      await adapter.loadBannerIfNeeded('k', 320);
      final listener = adapter.debugBannerListenerFor('k');

      adapter.disposeBannerInstance('k');

      expect(
          () => listener!.onAdFailedToLoad!(
              dummyBanner(), LoadAdError(0, 'd', 'm', null)),
          returnsNormally);
    });

    test('mrec onAdLoaded', () async {
      final adapter = await newAdapter();
      await adapter.loadMrecIfNeeded('k', 0);
      final listener = adapter.debugMrecListenerFor('k');
      expect(listener, isNotNull);

      adapter.disposeMrecInstance('k');

      expect(() => listener!.onAdLoaded!(dummyBanner()), returnsNormally);
    });

    test('mrec onAdFailedToLoad', () async {
      final adapter = await newAdapter();
      await adapter.loadMrecIfNeeded('k', 0);
      final listener = adapter.debugMrecListenerFor('k');

      adapter.disposeMrecInstance('k');

      expect(
          () => listener!.onAdFailedToLoad!(
              dummyBanner(), LoadAdError(0, 'd', 'm', null)),
          returnsNormally);
    });

    test('native onAdLoaded', () async {
      final adapter = await newAdapter();
      await adapter.preloadNative('k');
      final listener = adapter.debugNativeListenerFor('k');
      expect(listener, isNotNull);

      adapter.disposeNativeInstance('k');

      expect(() => listener!.onAdLoaded!(dummyBanner()), returnsNormally);
    });

    test('native onAdFailedToLoad', () async {
      final adapter = await newAdapter();
      await adapter.preloadNative('k');
      final listener = adapter.debugNativeListenerFor('k');

      adapter.disposeNativeInstance('k');

      expect(
          () => listener!.onAdFailedToLoad!(
              dummyBanner(), LoadAdError(0, 'd', 'm', null)),
          returnsNormally);
    });

    // T105 — onAdClicked had no identity guard at all (unlike
    // onAdLoaded/onAdFailedToLoad above), so a click arriving after dispose
    // still counted against CTR-fraud tracking and emitted an AdClickEvent
    // for a placement that no longer exists.
    //
    // Round-31 audit (MINOR) — banner/mrec used to wire this to onAdOpened
    // ("an overlay is presented in response to the user clicking"), not
    // onAdClicked ("the ad is clicked") like native — two events the
    // plugin documents as distinct with no guaranteed 1:1 mapping. Now
    // consistent across all three formats.
    test('banner onAdClicked (click) after dispose is dropped, not counted',
        () async {
      final adapter = await newAdapter();
      final events = <AdEvent>[];
      adapter.eventSink = events.add;
      await adapter.loadBannerIfNeeded('k', 320);
      final listener = adapter.debugBannerListenerFor('k');
      expect(listener, isNotNull);

      adapter.disposeBannerInstance('k');
      listener!.onAdClicked!(dummyBanner());

      expect(events, isEmpty,
          reason: 'a click landing after disposeBannerInstance() must not '
              'emit an AdClickEvent for a placement that no longer exists');
    });

    test('mrec onAdClicked (click) after dispose is dropped, not counted',
        () async {
      final adapter = await newAdapter();
      final events = <AdEvent>[];
      adapter.eventSink = events.add;
      await adapter.loadMrecIfNeeded('k', 0);
      final listener = adapter.debugMrecListenerFor('k');
      expect(listener, isNotNull);

      adapter.disposeMrecInstance('k');
      listener!.onAdClicked!(dummyBanner());

      expect(events, isEmpty);
    });

    test('native onAdClicked after dispose is dropped, not counted',
        () async {
      final adapter = await newAdapter();
      final events = <AdEvent>[];
      adapter.eventSink = events.add;
      await adapter.preloadNative('k');
      final listener = adapter.debugNativeListenerFor('k');
      expect(listener, isNotNull);

      adapter.disposeNativeInstance('k');
      listener!.onAdClicked!(dummyBanner());

      expect(events, isEmpty);
    });
  });

  // Round-31 audit (MAJOR) — banner/mrec/native used to count an impression
  // (and never emitted AdImpressionEvent at all) at onAdLoaded time — a fill,
  // not an actual on-screen impression. Now wired to the real onAdImpression
  // callback the plugin provides for exactly this.
  group('onAdImpression is the real impression signal, not onAdLoaded', () {
    test('banner: onAdLoaded alone emits no AdImpressionEvent; '
        'onAdImpression does', () async {
      final adapter = await newAdapter();
      final events = <AdEvent>[];
      adapter.eventSink = events.add;
      await adapter.loadBannerIfNeeded('k', 320);
      final listener = adapter.debugBannerListenerFor('k');
      expect(listener, isNotNull);

      listener!.onAdLoaded!(dummyBanner());
      expect(events.whereType<AdImpressionEvent>(), isEmpty,
          reason: 'a fill is not an impression');

      listener.onAdImpression!(dummyBanner());
      expect(events.whereType<AdImpressionEvent>(), hasLength(1));
      expect(events.whereType<AdImpressionEvent>().single.type,
          AdSlotType.banner);
    });

    test('mrec: onAdLoaded alone emits no AdImpressionEvent; '
        'onAdImpression does', () async {
      final adapter = await newAdapter();
      final events = <AdEvent>[];
      adapter.eventSink = events.add;
      await adapter.loadMrecIfNeeded('k', 0);
      final listener = adapter.debugMrecListenerFor('k');
      expect(listener, isNotNull);

      listener!.onAdLoaded!(dummyBanner());
      expect(events.whereType<AdImpressionEvent>(), isEmpty);

      listener.onAdImpression!(dummyBanner());
      expect(events.whereType<AdImpressionEvent>(), hasLength(1));
      expect(
          events.whereType<AdImpressionEvent>().single.type, AdSlotType.mrec);
    });

    test('native: onAdLoaded alone emits no AdImpressionEvent; '
        'onAdImpression does', () async {
      final adapter = await newAdapter();
      final events = <AdEvent>[];
      adapter.eventSink = events.add;
      await adapter.preloadNative('k');
      final listener = adapter.debugNativeListenerFor('k');
      expect(listener, isNotNull);

      listener!.onAdLoaded!(dummyBanner());
      expect(events.whereType<AdImpressionEvent>(), isEmpty);

      listener.onAdImpression!(dummyBanner());
      expect(events.whereType<AdImpressionEvent>(), hasLength(1));
      expect(events.whereType<AdImpressionEvent>().single.type,
          AdSlotType.native);
    });

    test(
        'a late onAdImpression arriving after dispose is dropped, not counted',
        () async {
      final adapter = await newAdapter();
      final events = <AdEvent>[];
      adapter.eventSink = events.add;
      await adapter.loadBannerIfNeeded('k', 320);
      final listener = adapter.debugBannerListenerFor('k');
      expect(listener, isNotNull);

      adapter.disposeBannerInstance('k');
      listener!.onAdImpression!(dummyBanner());

      expect(events, isEmpty,
          reason: 'an impression landing after disposeBannerInstance() '
              'must not emit an event for a placement that no longer '
              'exists, nor count toward CTR-fraud tracking');
    });
  });
}
