import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeInlineAdapter implements AdProviderAdapter, InlineAdVisibility {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot = AdSlot(
    type: AdSlotType.rewardedInterstitial,
  );
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

  bool inlineAdsHidden = false;
  int setInlineAdsHiddenCalls = 0;
  final Set<AdSlotType> hiddenFullscreenTypes = {};

  @override
  void setInlineAdsHidden(bool hidden) {
    inlineAdsHidden = hidden;
    setInlineAdsHiddenCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}

  @override
  String get tag => 'fake-inline';

  void Function(bool shown)? pendingInterstitialDone;
  void Function(RewardResult result)? pendingRewardedDone;
  void Function(bool dismissed)? pendingAppOpenDone;

  @override
  Future<void> showInterstitial({
    required void Function(bool shown) onDone,
  }) async {
    pendingInterstitialDone = onDone;
    interstitialSlot.beginShow();
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    pendingRewardedDone = onDone;
    rewardedSlot.beginShow();
  }

  @override
  Future<void> showAppOpen({
    required void Function(bool dismissed) onDismiss,
  }) async {
    pendingAppOpenDone = onDismiss;
    appOpenSlot.beginShow();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeInlineAdapter fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    fake = _FakeInlineAdapter();
    AdManager().debugSetAdapter(fake);
  });

  tearDown(() async {
    await AdManager().destroy();
  });

  test(
    'showInterstitial hides inline ads on start and holds hidden for 750ms after dismiss',
    () {
      fakeAsync((async) {
        fake.interstitialSlot.beginReload();
        fake.interstitialSlot.markReady();

        AdManager().showInterstitial(onDoneFlow: (_) {});
        async.flushMicrotasks();
        expect(fake.inlineAdsHidden, isTrue);

        fake.interstitialSlot.markDismissed();
        fake.pendingInterstitialDone?.call(true);
        async.flushMicrotasks();
        expect(fake.inlineAdsHidden, isTrue);

        async.elapse(const Duration(milliseconds: 749));
        expect(fake.inlineAdsHidden, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(fake.inlineAdsHidden, isFalse);
      });
    },
  );

  test(
    'showRewardedAd hides inline ads and restores after 750ms buffer following dismiss',
    () {
      fakeAsync((async) {
        fake.rewardedSlot.beginReload();
        fake.rewardedSlot.markReady();

        AdManager().showRewardedAd(onEarnedReward: (_) {});
        async.flushMicrotasks();
        expect(fake.inlineAdsHidden, isTrue);

        fake.rewardedSlot.markDismissed();
        fake.pendingRewardedDone?.call(
          const RewardResult(
            earned: true,
            shown: true,
            label: 'gold',
            amount: 5,
          ),
        );
        async.flushMicrotasks();
        expect(fake.inlineAdsHidden, isTrue);

        async.elapse(const Duration(milliseconds: 749));
        expect(fake.inlineAdsHidden, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(fake.inlineAdsHidden, isFalse);
      });
    },
  );

  test(
    'failed interstitial show restores inline ads immediately without 750ms delay',
    () {
      fakeAsync((async) {
        fake.interstitialSlot.beginReload();
        fake.interstitialSlot.markReady();

        AdManager().showInterstitial(onDoneFlow: (_) {});
        async.flushMicrotasks();
        expect(fake.inlineAdsHidden, isTrue);

        fake.interstitialSlot.markFailed();
        fake.pendingInterstitialDone?.call(false);
        async.flushMicrotasks();

        expect(fake.inlineAdsHidden, isFalse);
      });
    },
  );
}
