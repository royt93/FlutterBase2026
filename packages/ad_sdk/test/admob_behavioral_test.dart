// Behavioural tests for AdMobAdapter via the injectable GmaBridge. A
// FakeGmaBridge hands back fake fullscreen ads that capture the show callbacks,
// so the reward earned-vs-dismissed logic, the dismiss(true)/fail(false)
// resolution and the load-failure path are all exercised without the native
// google_mobile_ads plugin — giving AdMob the same behavioural coverage as
// AppLovin (a partner may run either provider).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/gma_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGmaFullscreenAd implements GmaFullscreenAd {
  GmaShowCallbacks? shown;
  int showCount = 0;
  int disposeCount = 0;

  @override
  Future<void> show(GmaShowCallbacks callbacks) async {
    shown = callbacks;
    showCount++;
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {}

  @override
  void dispose() => disposeCount++;
}

class FakeGmaBridge implements GmaBridge {
  bool failNextLoad = false;

  FakeGmaFullscreenAd? lastAppOpen;
  FakeGmaFullscreenAd? lastInter;
  FakeGmaFullscreenAd? lastRewarded;

  // Captured non-personalized (npa) flag from the most recent load per slot.
  bool? npaAppOpen;
  bool? npaInter;
  bool? npaRewarded;

  // Captured restricted-data-processing (CCPA RDP) flag from the most recent
  // load per slot.
  bool? rdpAppOpen;
  bool? rdpInter;
  bool? rdpRewarded;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> updateRequestConfiguration(List<String> ids) async {}

  @override
  Future<void> loadAppOpen(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    npaAppOpen = nonPersonalizedAds;
    rdpAppOpen = restrictedDataProcessing;
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastAppOpen = ad;
    onLoaded(ad);
  }

  @override
  Future<void> loadInterstitial(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    npaInter = nonPersonalizedAds;
    rdpInter = restrictedDataProcessing;
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastInter = ad;
    onLoaded(ad);
  }

  @override
  Future<void> loadRewarded(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    npaRewarded = nonPersonalizedAds;
    rdpRewarded = restrictedDataProcessing;
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastRewarded = ad;
    onLoaded(ad);
  }
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGmaBridge bridge;
  late AdMobAdapter adapter;

  setUp(() async {
    bridge = FakeGmaBridge();
    adapter = AdMobAdapter(bridge: bridge);
    expect(await adapter.initialize(_config), isTrue);
  });

  group('Interstitial dismiss resolution', () {
    test('dismiss → onDone(true) and the ad is disposed', () async {
      await adapter.loadInterstitial();
      expect(adapter.interstitialSlot.isReady, isTrue);

      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);
      bridge.lastInter!.shown!.onDismissed!();

      expect(shown, isTrue);
      expect(bridge.lastInter!.disposeCount, 1);
    });

    test('fail-to-show → onDone(false)', () async {
      await adapter.loadInterstitial();
      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);
      bridge.lastInter!.shown!.onFailedToShow!('boom');
      expect(shown, isFalse);
    });
  });

  // T11 — single-use guard: a fullscreen ad can never be shown twice, and the
  // slot state machine (isReady + atomic beginShow + null-on-dismiss) blocks a
  // second show from ever touching a shown/disposed ad object.
  group('single-use / double-show guard', () {
    test('second showInterstitial while showing is rejected (shown once)',
        () async {
      await adapter.loadInterstitial();
      final ad = bridge.lastInter!;

      bool? first;
      await adapter.showInterstitial(onDone: (s) => first = s);
      expect(ad.showCount, 1);

      // Second call BEFORE dismiss — slot is `showing`, must be rejected and
      // must NOT invoke show() again or dispose the live ad.
      bool? second;
      await adapter.showInterstitial(onDone: (s) => second = s);
      expect(second, isFalse, reason: 'blocked by slot state');
      expect(ad.showCount, 1, reason: 'never shown twice');
      expect(ad.disposeCount, 0, reason: 'live ad not disposed mid-show');

      // Dismiss resolves the first call and disposes exactly once.
      ad.shown!.onDismissed!();
      expect(first, isTrue);
      expect(ad.disposeCount, 1);
    });

    test(
        'showInterstitial after dismiss is not-ready (no reuse of disposed ad)',
        () async {
      await adapter.loadInterstitial();
      final ad = bridge.lastInter!;
      await adapter.showInterstitial(onDone: (_) {});
      ad.shown!.onDismissed!(); // ad nulled + disposed, slot idle

      bool? again;
      await adapter.showInterstitial(onDone: (s) => again = s);
      expect(again, isFalse, reason: 'no ad loaded → not ready');
      expect(ad.showCount, 1, reason: 'disposed ad never shown again');
      expect(ad.disposeCount, 1, reason: 'no double dispose');
    });
  });

  group('Rewarded earned vs dismissed', () {
    test('earning then dismiss → earned=true exactly once', () async {
      await adapter.loadRewarded();
      var calls = 0;
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) {
        calls++;
        result = r;
      });

      bridge.lastRewarded!.shown!.onUserEarnedReward!(10, 'coins');
      bridge.lastRewarded!.shown!.onDismissed!(); // dismiss after earning

      expect(result, isNotNull);
      expect(result!.earned, isTrue);
      expect(result!.amount, 10);
      expect(calls, 1,
          reason: 'reward must fire once (earned wins over dismiss)');
    });

    test('dismiss WITHOUT earning → skipped (no reward)', () async {
      await adapter.loadRewarded();
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);

      bridge.lastRewarded!.shown!.onDismissed!(); // no reward fired

      expect(result, isNotNull);
      expect(result!.earned, isFalse);
    });
  });

  group('App Open dismiss resolution', () {
    test('dismiss → onDismiss(true) and ad disposed', () async {
      await adapter.loadAppOpen();
      expect(adapter.appOpenSlot.isReady, isTrue);

      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);
      bridge.lastAppOpen!.shown!.onDismissed!();

      expect(dismissed, isTrue);
      expect(bridge.lastAppOpen!.disposeCount, 1);
      addTearDown(() => adapter.dispose());
    });
  });

  group('Load failure', () {
    test('a failed load drops the slot into cooldown', () async {
      bridge.failNextLoad = true;
      await adapter.loadInterstitial();
      expect(adapter.interstitialSlot.isReady, isFalse);
      expect(adapter.interstitialSlot.value, AdSlotState.cooldown);
    });
  });

  // T02 — every AdMob AdRequest must carry the non-personalized (npa) flag
  // derived from consent. Conservative default = non-personalized.
  group('Non-personalized (npa) consent propagation', () {
    test('conservative default: npa=true before any consent applied', () async {
      expect(adapter.debugNonPersonalizedAds, isTrue,
          reason: 'adapter must default to non-personalized');
      await adapter.loadInterstitial();
      expect(bridge.npaInter, isTrue);
    });

    test('consent granted → npa=false on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: true));
      expect(adapter.debugNonPersonalizedAds, isFalse);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.npaInter, isFalse);
      expect(bridge.npaRewarded, isFalse);
      expect(bridge.npaAppOpen, isFalse);
    });

    test('consent declined → npa=true on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: false));
      expect(adapter.debugNonPersonalizedAds, isTrue);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.npaInter, isTrue);
      expect(bridge.npaRewarded, isTrue);
      expect(bridge.npaAppOpen, isTrue);
    });

    test('accept then revoke → later loads flip back to npa=true', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: true));
      await adapter.loadInterstitial();
      expect(bridge.npaInter, isFalse);

      adapter.applyConsent(const AdConsent(hasUserConsent: false));
      await adapter.loadRewarded();
      expect(bridge.npaRewarded, isTrue);
    });

    test('age-restricted/doNotSell alone do not enable personalization',
        () async {
      // Only hasUserConsent controls npa; other flags are orthogonal.
      adapter.applyConsent(
          const AdConsent(isAgeRestrictedUser: true, doNotSell: true));
      expect(adapter.debugNonPersonalizedAds, isTrue);
    });

    test('dispose resets to conservative (npa=true)', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: true));
      expect(adapter.debugNonPersonalizedAds, isFalse);
      await adapter.dispose();
      expect(adapter.debugNonPersonalizedAds, isTrue,
          reason: 're-init before consent must stay non-personalized');
    });
  });

  // T05 — CCPA `doNotSell` must map to AdMob restricted-data-processing (RDP),
  // forwarded per-request via GmaBridge, and must stay independent of the
  // GDPR (npa) and COPPA (age-restricted) flags.
  group('Restricted-data-processing (RDP/CCPA) consent propagation', () {
    test('conservative default: rdp=false before any consent applied',
        () async {
      expect(adapter.debugRestrictedDataProcessing, isFalse,
          reason: 'adapter must default to unrestricted');
      await adapter.loadInterstitial();
      expect(bridge.rdpInter, isFalse);
    });

    test('doNotSell=true → rdp=true on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      expect(adapter.debugRestrictedDataProcessing, isTrue);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.rdpInter, isTrue);
      expect(bridge.rdpRewarded, isTrue);
      expect(bridge.rdpAppOpen, isTrue);
    });

    test('doNotSell=false → rdp=false on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(doNotSell: false));
      expect(adapter.debugRestrictedDataProcessing, isFalse);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.rdpInter, isFalse);
      expect(bridge.rdpRewarded, isFalse);
      expect(bridge.rdpAppOpen, isFalse);
    });

    test('opt-out then opt-in → later loads flip back to rdp=false', () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      await adapter.loadInterstitial();
      expect(bridge.rdpInter, isTrue);

      adapter.applyConsent(const AdConsent(doNotSell: false));
      await adapter.loadRewarded();
      expect(bridge.rdpRewarded, isFalse);
    });

    test('hasUserConsent/isAgeRestrictedUser alone do not trigger RDP',
        () async {
      // Only doNotSell controls rdp; other flags are orthogonal.
      adapter.applyConsent(
          const AdConsent(hasUserConsent: true, isAgeRestrictedUser: true));
      expect(adapter.debugRestrictedDataProcessing, isFalse);
    });

    test('doNotSell alone does not enable personalization (npa unaffected)',
        () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      expect(adapter.debugRestrictedDataProcessing, isTrue);
      expect(adapter.debugNonPersonalizedAds, isTrue,
          reason: 'doNotSell must not flip npa');
    });

    test('dispose resets to conservative (rdp=false)', () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      expect(adapter.debugRestrictedDataProcessing, isTrue);
      await adapter.dispose();
      expect(adapter.debugRestrictedDataProcessing, isFalse,
          reason: 're-init before consent must stay unrestricted');
    });
  });
}
