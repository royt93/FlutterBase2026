import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTransitionAdapter implements AdProviderAdapter {
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

  int loadAppOpenCount = 0;
  int loadInterstitialCount = 0;
  int loadRewardedCount = 0;

  @override
  String get tag => 'transition_fake';

  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {
    loadAppOpenCount++;
    onAdLoaded?.call(true);
  }

  @override
  Future<void> loadInterstitial() async {
    loadInterstitialCount++;
  }

  @override
  Future<void> loadRewarded() async {
    loadRewardedCount++;
  }

  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> loadRewardedInterstitial() async {}
  @override
  void applyConsent(AdConsent consent) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _testConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTransitionAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    adapter = _FakeTransitionAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _testConfig;
    AdManager().debugVipManager = null;
    AdManager().debugReconnectDebounce = const Duration(milliseconds: 50);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
  });

  test(
    'offline transition disables ad requests and online re-enables safely',
    () async {
      AdManager().debugConnectivityChanged(false);
      expect(AdManager().isConnected, isFalse);

      // Bật mạng trở lại và đợi debounce
      AdManager().debugConnectivityChanged(true);
      expect(AdManager().isConnected, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Refill quét nạp lại các slot ad
      expect(adapter.loadAppOpenCount, greaterThanOrEqualTo(1));
      expect(adapter.loadInterstitialCount, greaterThanOrEqualTo(1));
    },
  );

  test(
    'rapid offline-online cycles do not cause unhandled exceptions',
    () async {
      for (var i = 0; i < 10; i++) {
        AdManager().debugConnectivityChanged(i.isEven);
      }
      AdManager().debugConnectivityChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(AdManager().isConnected, isTrue);
    },
  );
}
