// Round-73 audit — AdMob auto-refreshes a live banner/MREC and reports a
// refresh no-fill through the same onAdFailedToLoad callback, while the
// previous creative stays on screen. The handler used to tear the live ad
// down, so one no-fill blanked a good placement until the next app resume.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// ignore: implementation_imports
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
    ),
  );

  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAnchoredAdaptiveBannerAdSize') return AdSize.banner;
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  BannerAd dummy() => BannerAd(
        adUnitId: 'b',
        size: AdSize.banner,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );
  LoadAdError err() => LoadAdError(3, 'domain', 'no fill', null);

  Future<AdMobAdapter> newAdapter() async {
    final adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(config), isTrue);
    addTearDown(adapter.dispose);
    return adapter;
  }

  group('banner', () {
    test('a refresh no-fill keeps the live ad, slot ready and no error',
        () async {
      final a = await newAdapter();
      await a.loadBannerIfNeeded('k', 320);
      a.debugBannerListenerFor('k')!.onAdLoaded!(dummy());
      expect(a.banner('k').isLoaded.value, isTrue, reason: 'sanity');

      a.debugBannerListenerFor('k')!.onAdFailedToLoad!(dummy(), err());

      expect(a.banner('k').isLoaded.value, isTrue);
      expect(a.banner('k').needsRecovery, isFalse);
      expect(a.bannerSlot('k').isReady, isTrue);
    });

    test('a first-load no-fill still tears down and flags recovery', () async {
      final a = await newAdapter();
      await a.loadBannerIfNeeded('k', 320);

      a.debugBannerListenerFor('k')!.onAdFailedToLoad!(dummy(), err());

      expect(a.banner('k').isLoaded.value, isFalse);
      expect(a.banner('k').needsRecovery, isTrue);
      expect(a.bannerSlot('k').isReady, isFalse);
    });

    test('repeated refresh failures never blank the ad', () async {
      final a = await newAdapter();
      await a.loadBannerIfNeeded('k', 320);
      a.debugBannerListenerFor('k')!.onAdLoaded!(dummy());
      for (var i = 0; i < 5; i++) {
        a.debugBannerListenerFor('k')!.onAdFailedToLoad!(dummy(), err());
      }
      expect(a.banner('k').isLoaded.value, isTrue);
    });
  });

  group('mrec', () {
    test('a refresh no-fill keeps the live ad, slot ready and no error',
        () async {
      final a = await newAdapter();
      await a.loadMrecIfNeeded('k', 300);
      a.debugMrecListenerFor('k')!.onAdLoaded!(dummy());
      expect(a.mrec('k').isLoaded.value, isTrue, reason: 'sanity');

      a.debugMrecListenerFor('k')!.onAdFailedToLoad!(dummy(), err());

      expect(a.mrec('k').isLoaded.value, isTrue);
      expect(a.mrec('k').needsRecovery, isFalse);
      expect(a.mrecSlot('k').isReady, isTrue);
    });

    test('a first-load no-fill still tears down and flags recovery', () async {
      final a = await newAdapter();
      await a.loadMrecIfNeeded('k', 300);

      a.debugMrecListenerFor('k')!.onAdFailedToLoad!(dummy(), err());

      expect(a.mrec('k').isLoaded.value, isFalse);
      expect(a.mrec('k').needsRecovery, isTrue);
      expect(a.mrecSlot('k').isReady, isFalse);
    });
  });
}
