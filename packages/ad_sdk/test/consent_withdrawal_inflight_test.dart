// Round-7 audit, MAJOR — a consent withdrawal must also invalidate the load
// that is ALREADY in flight, not only the ads already cached.
//
// `discardCachedFullscreenAds()` (called when `setConsent` narrows consent)
// only ever dropped slots that were already `ready`. A slot still `loading`
// kept its request, and its callback then marked it `ready` as usual. That ad
// was requested under the OLD, wider consent (AdMob `npa=0`, AppLovin
// `setHasUserConsent(true)`), and withdrawing personalisation does NOT close
// the `canRequestAds` gate — so it was then shown like any other ad. The
// user's withdrawal was honoured for every later request and silently ignored
// for the one already in the air.
//
// Both adapters are covered because they take opposite routes to the same
// bug: AdMob owns the ad object (so it must be disposed, not just dropped),
// while AppLovin's cache is native and unreachable from Dart (so the fix is
// to keep the slot out of `ready`, which is what every show path checks).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/gma_bridge.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge, FakeGmaFullscreenAd;
import 'applovin_adapter_test.dart' show FakeAppLovinBridge;

/// Holds the interstitial load open so the test can decide when — and under
/// which consent state — the fill lands.
class _DeferredInterstitialBridge extends FakeGmaBridge {
  void Function(GmaFullscreenAd)? pendingOnLoaded;

  @override
  Future<void> loadInterstitial(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    npaInter = nonPersonalizedAds;
    pendingOnLoaded = onLoaded;
  }
}

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

const _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'k',
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

MaxAd _fakeMaxAd() => MaxAd('i', 'INTER', null, 'net', '', 0.0, 'exact', 'cid',
    'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0), null, null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdMob — a fill that lands after the withdrawal', () {
    test('is disposed instead of being cached as ready', () async {
      final bridge = _DeferredInterstitialBridge();
      final adapter = AdMobAdapter(bridge: bridge);
      expect(await adapter.initialize(_admobConfig), isTrue);
      addTearDown(adapter.dispose);

      adapter.applyConsent(const AdConsent(hasUserConsent: true));
      await adapter.loadInterstitial();
      expect(adapter.interstitialSlot.isLoading, isTrue,
          reason: 'sanity: the request is in flight');
      expect(bridge.npaInter, isFalse,
          reason: 'sanity: it went out as a personalised request');

      // The user withdraws personalisation while the request is in the air.
      await adapter.discardCachedFullscreenAds();

      final late = FakeGmaFullscreenAd();
      bridge.pendingOnLoaded!(late);

      expect(adapter.interstitialSlot.isReady, isFalse,
          reason: 'an ad requested under the old consent must not become the '
              'ad the next showInterstitial() serves');
      expect(late.disposeCount, 1,
          reason: 'and it must be released, not merely forgotten');
    });

    test('is kept when no withdrawal happened', () async {
      final bridge = _DeferredInterstitialBridge();
      final adapter = AdMobAdapter(bridge: bridge);
      expect(await adapter.initialize(_admobConfig), isTrue);
      addTearDown(adapter.dispose);

      await adapter.loadInterstitial();
      final ad = FakeGmaFullscreenAd();
      bridge.pendingOnLoaded!(ad);

      expect(adapter.interstitialSlot.isReady, isTrue);
      expect(ad.disposeCount, 0);
    });
  });

  group('AppLovin — a fill that lands after the withdrawal', () {
    test('does not make the slot ready, so no show path can reach it',
        () async {
      final bridge = FakeAppLovinBridge();
      final adapter = AppLovinAdapter(bridge: bridge);
      expect(await adapter.initialize(_appLovinConfig), isTrue);
      addTearDown(adapter.dispose);

      await adapter.loadInterstitial();
      expect(adapter.interstitialSlot.isLoading, isTrue,
          reason: 'sanity: the request is in flight');

      await adapter.discardCachedFullscreenAds();
      bridge.inter!.onAdLoadedCallback(_fakeMaxAd());

      expect(adapter.interstitialSlot.isReady, isFalse,
          reason: 'MAX may still hold this ad natively, but showInterstitial() '
              'refuses on !isReady — that is what keeps it off screen');

      var shown = true;
      await adapter.showInterstitial(onDone: (ok) => shown = ok);
      expect(shown, isFalse);
    });

    test('is kept when no withdrawal happened', () async {
      final bridge = FakeAppLovinBridge();
      final adapter = AppLovinAdapter(bridge: bridge);
      expect(await adapter.initialize(_appLovinConfig), isTrue);
      addTearDown(adapter.dispose);

      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(_fakeMaxAd());
      expect(adapter.interstitialSlot.isReady, isTrue);
    });
  });
  // The other half of the contract: a withdrawal must invalidate the load that
  // was in flight AT THE TIME, and nothing after it. Without the generation
  // stamp in `AdSlot.beginLoad`, every later load on that slot keeps comparing
  // against the pre-withdrawal generation and is discarded too — the user
  // withdraws personalisation once and never sees another ad.
  test('a load STARTED after the withdrawal is honoured normally', () async {
    final bridge = _DeferredInterstitialBridge();
    final adapter = AdMobAdapter(bridge: bridge);
    expect(await adapter.initialize(_admobConfig), isTrue);
    addTearDown(adapter.dispose);

    await adapter.discardCachedFullscreenAds();

    await adapter.loadInterstitial();
    final ad = FakeGmaFullscreenAd();
    bridge.pendingOnLoaded!(ad);

    expect(adapter.interstitialSlot.isReady, isTrue,
        reason: 'this request already carried the narrowed consent');
    expect(ad.disposeCount, 0);
  });
}
