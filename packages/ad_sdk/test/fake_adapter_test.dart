// T118 — FakeAdProviderAdapter: a fully offline AdProviderAdapter for
// CI/demo/App-Review builds that never talks to AdMob or AppLovin.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize() succeeds with no network/ad-unit ID', () async {
    final adapter = FakeAdProviderAdapter();
    expect(adapter.isInitialised, isFalse);
    final ok = await adapter.initialize(
      const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'x',
          interstitialId: 'x',
          appOpenId: 'x',
          rewardedId: 'x',
        ),
      ),
    );
    expect(ok, isTrue);
    expect(adapter.isInitialised, isTrue);
  });

  group('fullscreen load/show — success path', () {
    late FakeAdProviderAdapter adapter;
    setUp(() => adapter = FakeAdProviderAdapter());

    test('interstitial: load then show resolves shown=true', () async {
      await adapter.loadInterstitial();
      expect(adapter.interstitialSlot.isReady, isTrue);

      var shown = false;
      await adapter.showInterstitial(onDone: (s) => shown = s);
      expect(shown, isTrue);
      expect(adapter.interstitialSlot.isIdle, isTrue,
          reason: 'dismissed → back to idle, ready to load again');
    });

    test('rewarded: load then show resolves earned=true, shown=true',
        () async {
      await adapter.loadRewarded();
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);
      expect(result!.earned, isTrue);
      expect(result!.shown, isTrue);
    });

    test('appOpen: load then show resolves dismissed=true', () async {
      await adapter.loadAppOpen();
      var dismissed = false;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);
      expect(dismissed, isTrue);
    });

    test('rewardedInterstitial: load then show resolves earned=true',
        () async {
      await adapter.loadRewardedInterstitial();
      RewardResult? result;
      await adapter.showRewardedInterstitial(onDone: (r) => result = r);
      expect(result!.earned, isTrue);
    });
  });

  test('shouldSucceed=false makes every load fail, not crash', () async {
    final adapter = FakeAdProviderAdapter(shouldSucceed: false);
    var loaded = true;
    await adapter.loadInterstitial();
    adapter.interstitialSlot.state.addListener(() {});
    expect(adapter.interstitialSlot.isCooldown, isTrue);

    await adapter.loadRewarded();
    expect(adapter.rewardedSlot.isCooldown, isTrue);

    // showInterstitial on a never-readied slot must not throw, and must
    // resolve shown=false rather than hang.
    await adapter.showInterstitial(onDone: (s) => loaded = s);
    expect(loaded, isFalse);
  });

  test('show without a prior load resolves as not-shown, does not throw',
      () async {
    final adapter = FakeAdProviderAdapter();
    var shown = true;
    await adapter.showInterstitial(onDone: (s) => shown = s);
    expect(shown, isFalse);
  });

  group('banner/mrec/native — per-key loading', () {
    test('banner: loadBannerIfNeeded flips isLoaded and renders a view',
        () async {
      final adapter = FakeAdProviderAdapter();
      final key = Object();
      expect(adapter.buildAdmobBannerView(key), isNull);

      await adapter.loadBannerIfNeeded(key, 320);

      expect(adapter.banner(key).isLoaded.value, isTrue);
      expect(adapter.buildAdmobBannerView(key), isNotNull);

      adapter.disposeBannerInstance(key);
      // Disposing must not throw, and frees the key — a fresh AdSlot comes
      // back idle, not the disposed one.
      expect(adapter.bannerSlot(key).isIdle, isTrue);
    });

    test('mrec: loadMrecIfNeeded flips isLoaded and renders a view',
        () async {
      final adapter = FakeAdProviderAdapter();
      final key = Object();
      await adapter.loadMrecIfNeeded(key, 300);
      expect(adapter.mrec(key).isLoaded.value, isTrue);
      expect(adapter.buildAdmobMrecView(key), isNotNull);
      adapter.disposeMrecInstance(key);
    });

    test('native: preloadNative flips isLoaded and renders a view', () async {
      final adapter = FakeAdProviderAdapter();
      final key = Object();
      await adapter.preloadNative(key);
      expect(adapter.native(key).isLoaded.value, isTrue);
      expect(adapter.buildAdmobNativeView(key), isNotNull);
      adapter.disposeNativeInstance(key);
    });

    test('two simultaneous banner keys are independent (T65-style parity)',
        () async {
      final adapter = FakeAdProviderAdapter();
      final keyA = Object();
      final keyB = Object();
      await adapter.loadBannerIfNeeded(keyA, 320);
      expect(adapter.banner(keyA).isLoaded.value, isTrue);
      expect(adapter.banner(keyB).isLoaded.value, isFalse);
    });
  });

  test('dispose() releases every slot/listenable without throwing',
      () async {
    final adapter = FakeAdProviderAdapter();
    await adapter.initialize(
      const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'x',
          interstitialId: 'x',
          appOpenId: 'x',
          rewardedId: 'x',
        ),
      ),
    );
    await adapter.loadInterstitial();
    await adapter.loadBannerIfNeeded(Object(), 320);

    await adapter.dispose();

    expect(adapter.isInitialised, isFalse);
  });

  test('AppLovin-only surface is stubbed, not wired (fake always renders '
      'through the AdMob-style build*View path)', () {
    final adapter = FakeAdProviderAdapter();
    expect(adapter.appLovinBannerId, isNull);
    expect(adapter.appLovinMrecId, isNull);
    expect(adapter.appLovinNativeId, isNull);
  });
}
