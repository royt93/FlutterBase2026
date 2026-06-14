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

  @override
  Future<void> initialize() async {}
  @override
  Future<void> updateRequestConfiguration(List<String> ids) async {}

  @override
  Future<void> loadAppOpen(String id,
      {required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastAppOpen = ad;
    onLoaded(ad);
  }

  @override
  Future<void> loadInterstitial(String id,
      {required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastInter = ad;
    onLoaded(ad);
  }

  @override
  Future<void> loadRewarded(String id,
      {required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
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
      expect(calls, 1, reason: 'reward must fire once (earned wins over dismiss)');
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
}
