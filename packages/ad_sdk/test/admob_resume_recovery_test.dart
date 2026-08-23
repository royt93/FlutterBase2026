// Round-6 audit, the same defect as the AppLovin one in
// applovin_adapter_test.dart ("a recovery attempt refused by the backoff…") —
// found on AppLovin first, but AdMob's three `onAppResumed` recovery loops
// (banner, MREC, native) had it identically, and unlike AppLovin's they had no
// test at all.
//
// `hasError` used to mean two things: "paint nothing" AND "this key still owes
// a retry". Each recovery loop cleared it, then called a load that can refuse
// (the slot is in its failure backoff — a banner that just failed always is).
// On a refusal the key was left with no error flag, no ad, and nothing that
// would ever bring it back: the widget sat on its shimmer placeholder for the
// rest of the session.
//
// The split (`BannerListenables.needsRecovery`, cleared only by a real
// success) is what these three tests pin down. They drive the REAL listeners
// the production load path created — same seams as admob_late_callback_test —
// so reverting the gate makes them fail for real.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// AdMessageCodec isn't exported public API — same workaround as
// admob_late_callback_test/gma_bridge_test, needed to match the plugin's codec.
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

  BannerAd dummyBanner() => BannerAd(
        adUnitId: 'b',
        size: AdSize.banner,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );

  NativeAd dummyNative() => NativeAd(
        adUnitId: 'n',
        request: const AdRequest(),
        listener: NativeAdListener(),
        nativeTemplateStyle:
            NativeTemplateStyle(templateType: TemplateType.medium),
      );

  Future<AdMobAdapter> newAdapter() async {
    final adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(config), isTrue);
    addTearDown(adapter.dispose);
    return adapter;
  }

  // Two microtask turns: the recovery loops call the async loadX paths without
  // awaiting them.
  Future<void> settle() async {
    await Future<void>.value();
    await Future<void>.value();
    await Future<void>.value();
  }

  LoadAdError err() => LoadAdError(3, 'domain', 'no fill', null);

  group('onAppResumed recovery survives a refused retry (needsRecovery)', () {
    test('banner', () async {
      final a = await newAdapter();
      await a.loadBannerIfNeeded('k', 320);
      final listener = a.debugBannerListenerFor('k');
      expect(listener, isNotNull, reason: 'sanity: real load path ran');

      listener!.onAdFailedToLoad!(dummyBanner(), err());
      expect(a.banner('k').hasError.value, isTrue);
      expect(a.banner('k').needsRecovery, isTrue,
          reason: 'a real no-fill is what creates the retry claim');
      expect(a.debugBannerListenerFor('k'), isNull,
          reason: 'sanity: the failed ad was dropped from the map');

      a.onAppResumed();
      await settle();

      expect(a.debugBannerListenerFor('k'), isNull,
          reason: 'the slot is inside its failure backoff, so beginLoad() '
              'refuses and no new ad is created');
      expect(a.banner('k').hasError.value, isFalse,
          reason: 'display flag cleared — the widget shows its shimmer');
      expect(a.banner('k').needsRecovery, isTrue,
          reason: 'THE FIX: the claim must outlive a refused attempt. While it '
              'lived in `hasError`, this recovery loop erased its own re-entry '
              'condition and the banner never came back');

      // The backoff window elapses (15s base for a single failure).
      a.bannerSlot('k').lastErrorAt =
          DateTime.now().subtract(const Duration(seconds: 20));

      a.onAppResumed();
      await settle();

      expect(a.debugBannerListenerFor('k'), isNotNull,
          reason: 'the next resume finds the claim still set and retries');
    });

    test('MREC', () async {
      final a = await newAdapter();
      await a.loadMrecIfNeeded('k', 0);
      final listener = a.debugMrecListenerFor('k');
      expect(listener, isNotNull);

      listener!.onAdFailedToLoad!(dummyBanner(), err());
      expect(a.mrec('k').needsRecovery, isTrue);

      a.onAppResumed();
      await settle();

      expect(a.debugMrecListenerFor('k'), isNull, reason: 'backoff refused');
      expect(a.mrec('k').hasError.value, isFalse);
      expect(a.mrec('k').needsRecovery, isTrue);

      a.mrecSlot('k').lastErrorAt =
          DateTime.now().subtract(const Duration(seconds: 20));
      a.onAppResumed();
      await settle();

      expect(a.debugMrecListenerFor('k'), isNotNull);
    });

    test('native', () async {
      final a = await newAdapter();
      await a.preloadNative('k');
      final listener = a.debugNativeListenerFor('k');
      expect(listener, isNotNull);

      listener!.onAdFailedToLoad!(dummyNative(), err());
      expect(a.native('k').needsRecovery, isTrue);

      a.onAppResumed();
      await settle();

      expect(a.debugNativeListenerFor('k'), isNull, reason: 'backoff refused');
      expect(a.native('k').hasError.value, isFalse);
      expect(a.native('k').needsRecovery, isTrue);

      a.nativeSlot('k').lastErrorAt =
          DateTime.now().subtract(const Duration(seconds: 20));
      a.onAppResumed();
      await settle();

      expect(a.debugNativeListenerFor('k'), isNotNull);
    });

    // The other half of the invariant: a claim that is never settled would make
    // every later resume tear a healthy ad down and re-request it.
    test('a successful load settles the claim', () async {
      final a = await newAdapter();
      await a.loadBannerIfNeeded('k', 320);
      final listener = a.debugBannerListenerFor('k')!;

      listener.onAdFailedToLoad!(dummyBanner(), err());
      expect(a.banner('k').needsRecovery, isTrue);

      a.bannerSlot('k').lastErrorAt =
          DateTime.now().subtract(const Duration(seconds: 20));
      a.onAppResumed();
      await settle();

      final retried = a.debugBannerListenerFor('k');
      expect(retried, isNotNull, reason: 'sanity: the retry went out');
      retried!.onAdLoaded!(dummyBanner());

      expect(a.banner('k').needsRecovery, isFalse);
      expect(a.banner('k').hasError.value, isFalse);
    });
  });
}
