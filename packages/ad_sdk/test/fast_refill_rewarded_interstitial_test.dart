// T148 — the two "fast-refill" paths that avoid waiting out the 5-minute
// retry timer after VIP ends or after the first App Open slot settles
// (`_onVipActiveChanged`, `_onAppOpenStateChange`) reload App Open +
// Interstitial + Rewarded, but never Rewarded Interstitial. A host using
// that format had to wait up to 5 minutes for it to refill after either
// event, unlike its three siblings.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
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
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  int loadInterstitialCalls = 0;
  int loadRewardedCalls = 0;
  int loadRewardedInterstitialCalls = 0;

  @override
  String get tag => 'counting';
  @override
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;

  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;
  @override
  Future<void> loadRewarded() async => loadRewardedCalls++;
  @override
  Future<void> loadRewardedInterstitial() async =>
      loadRewardedInterstitialCalls++;
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> applyConsent(AdConsent consent) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  safety: AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'VIP ending reloads rewardedInterstitial too, not just the other '
      'three fast-refill surfaces', () async {
    late _CountingAdapter adapter;
    AdManager.debugAdapterFactory = (_) => adapter = _CountingAdapter();
    await AdManager().initialize(config: _config, onComplete: (_, __) {});
    final vip = AdManager().vip!;
    await vip.revokeAll();
    await vip.addVip(key: 'PAID', duration: const Duration(hours: 1));
    expect(vip.isActive, isTrue, reason: 'sanity');
    AdManager().debugCanRequestAds = true;
    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(true);
    adapter.loadInterstitialCalls = 0;
    adapter.loadRewardedCalls = 0;
    adapter.loadRewardedInterstitialCalls = 0;

    await vip.revokeAll();
    expect(vip.isActive, isFalse, reason: 'sanity');

    expect(adapter.loadInterstitialCalls, greaterThan(0),
        reason: 'sanity: the fast-refill path did run');
    expect(adapter.loadRewardedCalls, greaterThan(0),
        reason: 'sanity: the fast-refill path did run');
    expect(adapter.loadRewardedInterstitialCalls, greaterThan(0),
        reason: 'T148 — rewardedInterstitial must be reloaded on the same '
            'fast-refill path as its three siblings, not left to wait out '
            'the 5-minute retry timer');
  });

  test(
      'the first App Open slot settling reloads rewardedInterstitial too, '
      'not just Interstitial and Rewarded', () async {
    late _CountingAdapter adapter;
    AdManager.debugAdapterFactory = (_) => adapter = _CountingAdapter();
    await AdManager().initialize(config: _config, onComplete: (_, __) {});
    // initialize()'s own auto-UMP flow overwrites canRequestAds during its
    // async gate resolution — re-assert AFTER it settles, not before.
    AdManager().debugCanRequestAds = true;
    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(true);
    adapter.loadInterstitialCalls = 0;
    adapter.loadRewardedCalls = 0;
    adapter.loadRewardedInterstitialCalls = 0;

    // loadAppOpenAd()'s own consent/network skip path (exercised once during
    // initialize() above) never touches the slot's state — so the listener
    // _scheduleFirstSecondaryLoad() attached is still armed here. Driving it
    // now is the slot's actual FIRST ready/cooldown transition.
    adapter.appOpenSlot.beginLoad();
    adapter.appOpenSlot.markReady();

    expect(adapter.loadInterstitialCalls, greaterThan(0),
        reason: 'sanity: the first-secondary-load path did run');
    expect(adapter.loadRewardedCalls, greaterThan(0),
        reason: 'sanity: the first-secondary-load path did run');
    expect(adapter.loadRewardedInterstitialCalls, greaterThan(0),
        reason: 'T148 — rewardedInterstitial must be reloaded the first '
            'time the App Open slot settles, same as its two siblings here');
  });
}
