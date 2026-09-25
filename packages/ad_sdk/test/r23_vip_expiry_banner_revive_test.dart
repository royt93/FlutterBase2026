// Round-23 QC (reviewer C, MINOR) — when a VIP entitlement runs out, the ads
// must come back on the screen the user is actually looking at.
//
// Every inline ad widget re-attempts its load from the `initRevision` builder:
// that notifier is the SDK's "conditions changed, try again where there is no
// ad yet" signal. The VIP listener is a *separate, inner* builder, and it only
// controls whether the surface is drawn.
//
// So a widget that mounted while VIP was active never ran `_initBanner` at
// all, and nothing re-ran it when the entitlement expired: `_onVipActiveChanged`
// kicked the three fullscreen preloads and the two warm-up surfaces, but never
// told the mounted widgets to try. The banner stayed blank until a route change
// or an app restart — on the one screen where the user had just watched their
// VIP window end.
//
// Two halves, proven separately because they live in different layers:
//   1. losing VIP bumps `initRevision`;
//   2. a bump is what makes a VIP-suppressed banner load.

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
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  final Map<Object, AdSlot> _bannerSlotsByKey = {};
  final Map<Object, BannerListenables> _bannerListenablesByKey = {};
  int loadBannerCalls = 0;

  @override
  AdSlot bannerSlot(Object key) =>
      _bannerSlotsByKey.putIfAbsent(key, () => AdSlot(type: AdSlotType.banner));
  @override
  Iterable<AdSlot> get bannerSlots => _bannerSlotsByKey.values;
  @override
  BannerListenables banner(Object key) =>
      _bannerListenablesByKey.putIfAbsent(
          key,
          () => BannerListenables(
                isLoaded: ValueNotifier<bool>(false),
                hasError: ValueNotifier<bool>(false),
                adSize: ValueNotifier<Size?>(null),
                autoRefreshEnabled: ValueNotifier<bool>(true),
                visible: ValueNotifier<bool>(true),
              ));
  @override
  bool bannerRoutePaused(Object key) => false;
  @override
  void disposeBannerInstance(Object key) {
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
  }) async =>
      true;

  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async =>
      loadBannerCalls++;
  @override
  Future<void> preloadBanner(Object key) async {}
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
  Widget? buildAdmobBannerView(Object key) => null;
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

  group('1. losing VIP asks the mounted widgets to retry', () {
    Future<VipManager> initWithVip() async {
      AdManager.debugAdapterFactory = (_) => _BannerCountingAdapter();
      await AdManager().initialize(config: _config, onComplete: (_, _) {});
      final vip = AdManager().vip!;
      await vip.revokeAll();
      await vip.addVip(key: 'PAID', duration: const Duration(hours: 1));
      expect(vip.isActive, isTrue, reason: 'sanity');
      return vip;
    }

    test('revoking the last entry bumps initRevision', () async {
      final vip = await initWithVip();
      final before = AdManager().initRevision.value;

      await vip.revokeAll();

      expect(vip.isActive, isFalse, reason: 'sanity');
      expect(AdManager().initRevision.value, greaterThan(before),
          reason: 'THE finding: the fullscreen slots were re-preloaded but the '
              'inline widgets on screen were never told to try again');
    });

    test('CONTROL — gaining VIP does not bump it', () async {
      AdManager.debugAdapterFactory = (_) => _BannerCountingAdapter();
      await AdManager().initialize(config: _config, onComplete: (_, _) {});
      final vip = AdManager().vip!;
      await vip.revokeAll();
      final before = AdManager().initRevision.value;

      await vip.addVip(key: 'PAID', duration: const Duration(hours: 1));

      expect(vip.isActive, isTrue);
      expect(AdManager().initRevision.value, before,
          reason: 'a fresh VIP must suppress ads, not go looking for more');
    });
  });

  group('2. a bump is what makes a suppressed banner load', () {
    Widget host(Widget child) => MaterialApp(
          navigatorObservers: [adRouteObserver],
          home: Scaffold(body: Center(child: child)),
        );

    testWidgets('a banner mounted under VIP loads as soon as VIP ends',
        (tester) async {
      final adapter = _BannerCountingAdapter();
      final vip = _FakeVip(true);
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      AdManager().debugCanRequestAds = true;
      AdManager().debugVipManager = vip;
      AdManager().debugResetBannerCooldown();
      // `destroy()` in a previous test leaves the connectivity watch reading
      // offline, and `_initBanner` refuses to load offline for its own reasons.
      AdManager().debugConnectivityReady = false;
      AdManager().debugConnectivityChanged(true);

      await tester.pumpWidget(host(const BannerAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 0,
          reason: 'sanity — a VIP is not shown ads');

      // What `_onVipActiveChanged` does in production, in the same order.
      vip.active = false;
      AdManager().initRevision.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 1,
          reason: 'without the bump this widget never re-runs _initBanner, so '
              'the surface stays blank until a route change');

      // Drain the connectivity-change debounce so the binding does not fail
      // the test on a pending timer.
      await tester.pump(const Duration(milliseconds: 900));
    });
  });
}
