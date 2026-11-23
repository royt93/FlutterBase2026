// Repro (MREC twin of banner_mounted_before_init_test.dart): a MrecAdWidget mounted on the FIRST frame (before the SDK has
// finished initialising, while a first-install VIP grace is active) must paint
// its banner once init completes and VIP ends. Seen on a Galaxy S24 Ultra with
// a hosted 3.7.8 consumer app: the log said loadBanner OK but nothing was
// drawn; the same widget mounted 40 s later painted fine.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BannerCountingAdapter implements AdProviderAdapter {
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

  final Map<Object, AdSlot> _bannerSlotsByKey = {};
  final Map<Object, BannerListenables> _bannerListenablesByKey = {};
  int loadBannerCalls = 0;
  int loadMrecCalls = 0;
  final Map<Object, AdSlot> _mrecSlots = {};
  final Map<Object, BannerListenables> _mrecListenables = {};
  int disposeBannerCalls = 0;

  @override
  AdSlot bannerSlot(Object key) =>
      _bannerSlotsByKey.putIfAbsent(key, () => AdSlot(type: AdSlotType.banner));
  @override
  Iterable<AdSlot> get bannerSlots => _bannerSlotsByKey.values;
  @override
  BannerListenables banner(Object key) => _bannerListenablesByKey.putIfAbsent(
    key,
    () => BannerListenables(
      isLoaded: ValueNotifier<bool>(false),
      hasError: ValueNotifier<bool>(false),
      adSize: ValueNotifier<Size?>(null),
      autoRefreshEnabled: ValueNotifier<bool>(true),
      visible: ValueNotifier<bool>(true),
    ),
  );
  @override
  bool bannerRoutePaused(Object key) => false;
  @override
  void disposeBannerInstance(Object key) {
    disposeBannerCalls++;
    _bannerSlotsByKey.remove(key);
    _bannerListenablesByKey.remove(key);
  }

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
  }) async => true;

  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {
    loadBannerCalls++;
    banner(key).isLoaded.value = true;
    banner(key).adSize.value = const Size(320, 50);
  }

  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  AdSlot mrecSlot(Object key) =>
      _mrecSlots.putIfAbsent(key, () => AdSlot(type: AdSlotType.mrec));
  @override
  Iterable<AdSlot> get mrecSlots => _mrecSlots.values;
  @override
  BannerListenables mrec(Object key) => _mrecListenables.putIfAbsent(
    key,
    () => BannerListenables(
      isLoaded: ValueNotifier<bool>(false),
      hasError: ValueNotifier<bool>(false),
      adSize: ValueNotifier<Size?>(null),
      autoRefreshEnabled: ValueNotifier<bool>(true),
      visible: ValueNotifier<bool>(true),
    ),
  );
  @override
  Future<void> loadMrecIfNeeded(Object key, double widthPx) async {
    loadMrecCalls++;
    mrec(key).isLoaded.value = true;
    mrec(key).adSize.value = const Size(300, 250);
  }

  @override
  void disposeMrecInstance(Object key) {
    _mrecSlots.remove(key);
    _mrecListenables.remove(key);
  }

  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Widget? buildAdmobMrecView(Object key) =>
      const SizedBox(key: ValueKey('fake-mrec-view'), height: 250);
  @override
  Widget? buildAdmobBannerView(Object key) =>
      const SizedBox(key: ValueKey('fake-banner-view'), height: 50);
  @override
  Future<void> applyConsent(AdConsent consent) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVip implements VipManager {
  _FakeVip(bool active) : activeListenable = ValueNotifier<bool>(active);
  @override
  final ValueNotifier<bool> activeListenable;
  set active(bool v) => activeListenable.value = v;
  @override
  bool get isActive => activeListenable.value;
  @override
  void dispose() => activeListenable.dispose();
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

  Widget host(Widget child) => MaterialApp(
    navigatorObservers: [adRouteObserver],
    home: Scaffold(
      body: SingleChildScrollView(child: Column(children: [child])),
    ),
  );

  testWidgets('MREC mounted before init paints once init completes', (
    tester,
  ) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(true);

    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadMrecCalls, 0, reason: 'sanity: nothing to load yet');

    AdManager().debugVipManager = _FakeVip(false);
    AdManager().debugConfig = _config;
    AdManager().debugSetAdapter(adapter);
    AdManager().initRevision.value++;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      adapter.loadMrecCalls,
      greaterThanOrEqualTo(1),
      reason: 'the MREC must be requested',
    );
    expect(
      find.byKey(const ValueKey('fake-mrec-view')),
      findsOneWidget,
      reason:
          'a loaded MREC must actually be in the tree, not a blank '
          'placeholder',
    );
    await tester.pump(const Duration(milliseconds: 2500));
  });
}
