// Round-73 audit — an AdMob banner/MREC/native whose first load failed while
// offline stayed blank after the network came back: preloadBanner is a no-op
// on AdMob, the mounted widget keeps `_allowed == true`, and the refill scan
// only covers fullscreen slots. Recovery used to wait for the next app resume.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// ignore: implementation_imports
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;
import 'package:shared_preferences/shared_preferences.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge;

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    mrecId: 'm',
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

  BannerAd dummy() => BannerAd(
        adUnitId: 'b',
        size: AdSize.banner,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );
  LoadAdError err() => LoadAdError(2, 'domain', 'network error', null);

  late AdMobAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAnchoredAdaptiveBannerAdSize') return AdSize.banner;
      return null;
    });
    adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(_config), isTrue);
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config;
    AdManager().debugVipManager = null;
    AdManager().debugReconnectDebounce = const Duration(milliseconds: 10);
  });

  tearDown(() async {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    await adapter.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  // ── unit: adapter ─────────────────────────────────────────────────────────
  group('AdMobAdapter.recoverInlineAdsAfterReconnect', () {
    test('a banner that failed offline is requested again', () async {
      await adapter.loadBannerIfNeeded('k', 320);
      adapter.debugBannerListenerFor('k')!.onAdFailedToLoad!(dummy(), err());
      expect(adapter.banner('k').needsRecovery, isTrue, reason: 'sanity');
      final before = adapter.debugBannerListenerFor('k');

      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(adapter.debugBannerListenerFor('k'), isNot(same(before)),
          reason: 'a fresh load (new listener) must have been issued');
      expect(adapter.bannerSlot('k').isLoading, isTrue);
    });

    test('a banner that already has an ad is left alone', () async {
      await adapter.loadBannerIfNeeded('k', 320);
      adapter.debugBannerListenerFor('k')!.onAdLoaded!(dummy());
      final before = adapter.debugBannerListenerFor('k');

      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(adapter.debugBannerListenerFor('k'), same(before));
      expect(adapter.banner('k').isLoaded.value, isTrue);
    });

    test('a key that never failed is left alone', () async {
      adapter.banner('fresh');
      adapter.recoverInlineAdsAfterReconnect();
      await settle();
      expect(adapter.debugBannerListenerFor('fresh'), isNull);
    });

    test('an MREC that failed offline is requested again', () async {
      await adapter.loadMrecIfNeeded('k', 0);
      adapter.debugMrecListenerFor('k')!.onAdFailedToLoad!(dummy(), err());
      final before = adapter.debugMrecListenerFor('k');

      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(adapter.debugMrecListenerFor('k'), isNot(same(before)));
    });

    test('does nothing while the load gate is closed', () async {
      await adapter.loadBannerIfNeeded('k', 320);
      adapter.debugBannerListenerFor('k')!.onAdFailedToLoad!(dummy(), err());
      final before = adapter.debugBannerListenerFor('k');
      adapter.canReload = () => false;

      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(adapter.debugBannerListenerFor('k'), same(before),
          reason: 'consent/VIP/cap/offline gate must still be honoured');
    });

    test('every failed key is recovered, not just the first', () async {
      for (final k in ['a', 'b', 'c']) {
        await adapter.loadBannerIfNeeded(k, 320);
        adapter.debugBannerListenerFor(k)!.onAdFailedToLoad!(dummy(), err());
      }
      final before = {
        for (final k in ['a', 'b', 'c']) k: adapter.debugBannerListenerFor(k)
      };

      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      for (final k in ['a', 'b', 'c']) {
        expect(adapter.debugBannerListenerFor(k), isNot(same(before[k])),
            reason: 'key $k');
      }
    });
  });

  // ── integration of the manager path: offline → online ────────────────────
  group('AdManager reconnect wiring', () {
    test('offline→online re-requests a banner that failed while offline',
        () async {
      AdManager().debugConnectivityChanged(true);
      await adapter.loadBannerIfNeeded('k', 320);
      adapter.debugBannerListenerFor('k')!.onAdFailedToLoad!(dummy(), err());
      final before = adapter.debugBannerListenerFor('k');

      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(adapter.debugBannerListenerFor('k'), isNot(same(before)),
          reason: 'the reconnect handler must now reach AdMob inline ads');
    });

    test('flapping collapses to one recovery request, not a request storm',
        () async {
      AdManager().debugConnectivityChanged(true);
      await adapter.loadBannerIfNeeded('k', 320);
      adapter.debugBannerListenerFor('k')!.onAdFailedToLoad!(dummy(), err());

      for (var i = 0; i < 6; i++) {
        AdManager().debugConnectivityChanged(false);
        AdManager().debugConnectivityChanged(true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(adapter.bannerSlot('k').isLoading, isTrue);
    });
  });
}
