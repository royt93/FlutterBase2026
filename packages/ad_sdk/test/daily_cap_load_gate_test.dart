// T21 — load-time daily safety cap gate: once AdSafetyConfig.dailyCapReached()
// is true, load*() must skip the adapter entirely instead of only gating at
// show time. VIP members never reach the new check at all — the pre-existing
// VIP guard in every load*() returns before it.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int loadInterstitialCalls = 0;
  int loadRewardedCalls = 0;
  int loadAppOpenCalls = 0;

  @override
  String get tag => 'counting';
  @override
  Future<void> showInterstitial({
    required void Function(bool shown) onDone,
  }) async =>
      onDone(true);
  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;
  @override
  Future<void> loadRewarded() async => loadRewardedCalls++;
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async =>
      loadAppOpenCalls++;
  @override
  void applyConsent(AdConsent consent) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;
  @override
  bool get isActive => _active;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/1111111111',
    interstitialId: 'ca-app-pub-3940256099942544/2222222222',
    appOpenId: 'ca-app-pub-3940256099942544/3333333333',
    rewardedId: 'ca-app-pub-3940256099942544/4444444444',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late _CountingAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    adapter = _CountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config;
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true;
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true;
  });

  group('daily cap load gate', () {
    test('cap reached → loadInterstitial/loadRewardedAd/loadAppOpenAd all skip',
        () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(maxFullscreenAdsPerDay: 0));
      AdSafetyConfig.resetForReinit();

      await AdManager().loadInterstitial();
      await AdManager().loadRewardedAd();
      await AdManager().loadAppOpenAd();

      expect(adapter.loadInterstitialCalls, 0);
      expect(adapter.loadRewardedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
    });

    test('cap not reached → loads reach the adapter', () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(maxFullscreenAdsPerDay: 5));
      AdSafetyConfig.resetForReinit();

      await AdManager().loadInterstitial();
      await AdManager().loadRewardedAd();
      await AdManager().loadAppOpenAd();

      expect(adapter.loadInterstitialCalls, 1);
      expect(adapter.loadRewardedCalls, 1);
      expect(adapter.loadAppOpenCalls, 1);
    });

    test(
        'VIP member still skips load — pre-existing VIP guard fires before '
        'the new cap check, so dailyCapReached() is never even reached',
        () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(maxFullscreenAdsPerDay: 0));
      AdSafetyConfig.resetForReinit();
      AdManager().debugVipManager = _FakeVip(true);

      await AdManager().loadInterstitial();

      expect(adapter.loadInterstitialCalls, 0,
          reason: 'VIP members never load fullscreen ads at all (ads are '
              'suppressed for VIP) — this pins that the new cap guard did '
              'not change that pre-existing early return');
    });
  });
}
