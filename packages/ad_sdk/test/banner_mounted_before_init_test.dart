// Repro: a BannerAdWidget mounted on the FIRST frame (before the SDK has
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
    home: Scaffold(body: Column(children: [child])),
  );

  testWidgets(
    'banner mounted before init paints once init completes and VIP ends',
    (tester) async {
      final adapter = _BannerCountingAdapter();
      final vip = _FakeVip(true);
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
      AdManager().debugConnectivityReady = false;
      AdManager().debugConnectivityChanged(true);

      // First frame: no adapter yet (initialize() still running).
      await tester.pumpWidget(host(const BannerAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 0, reason: 'sanity: nothing to load yet');

      // initialize() completes while the first-install VIP grace is active.
      // The config only exists from here on, so isAdMobProvider was FALSE when
      // the widget's didPush ran on the first frame (as on a real device).
      AdManager().debugConfig = _config;
      AdManager().debugVipManager = vip;
      AdManager().debugSetAdapter(adapter);
      AdManager().initRevision.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Grace expires: production flips VIP off, then bumps initRevision.
      vip.active = false;
      AdManager().initRevision.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        adapter.loadBannerCalls,
        greaterThanOrEqualTo(1),
        reason: 'the banner must be requested',
      );
      expect(
        find.byKey(const ValueKey('fake-banner-view')),
        findsOneWidget,
        reason: 'a loaded banner must actually be in the tree',
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('fake-banner-view'))).height,
        greaterThan(0),
      );

      await tester.pump(const Duration(milliseconds: 2500));
    },
  );

  testWidgets(
    'route pushed over a pre-init banner then popped still paints it',
    (tester) async {
      final adapter = _BannerCountingAdapter();
      final vip = _FakeVip(false);
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
      AdManager().debugConnectivityReady = false;
      AdManager().debugConnectivityChanged(true);

      await tester.pumpWidget(host(const BannerAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        AdManager().isAdMobProvider,
        isFalse,
        reason: 'precondition: provider unknown before init',
      );
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('2')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        AdManager().isAdMobProvider,
        isFalse,
        reason: 'still unknown while covered, before init',
      );
      // init finishes while the banner is covered
      AdManager().debugVipManager = vip;
      AdManager().debugConfig = _config;
      AdManager().debugSetAdapter(adapter);
      AdManager().initRevision.value++;
      await tester.pump(const Duration(milliseconds: 100));

      nav.pop();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(const ValueKey('fake-banner-view')),
        findsOneWidget,
        reason:
            'after returning to the route the banner must be requested '
            'and drawn, not left as a blank placeholder',
      );
      await tester.pump(const Duration(milliseconds: 2500));
    },
  );

  // --- review follow-ups (2026-11-23) --------------------------------------

  Future<_BannerCountingAdapter> initAdMobNow() async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(true);
    AdManager().debugVipManager = _FakeVip(false);
    AdManager().debugConfig = _config;
    AdManager().debugSetAdapter(adapter);
    return adapter;
  }

  testWidgets('hidden (active:false) banner shows once it is activated', (
    tester,
  ) async {
    await initAdMobNow();
    Widget app(bool active) => MaterialApp(
      navigatorObservers: [adRouteObserver],
      home: Scaffold(
        body: Column(children: [BannerAdWidget(active: active)]),
      ),
    );
    await tester.pumpWidget(app(false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('fake-banner-view')), findsNothing);

    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('fake-banner-view')),
      findsOneWidget,
      reason:
          'didPush raises the AdMob flag independently of `active`; a '
          'guard on active would leave this blank after activation',
    );
    await tester.pump(const Duration(milliseconds: 2500));
  });

  testWidgets(
    'route pushed in the same frame as the mount: banner paints on pop',
    (tester) async {
      await initAdMobNow();
      final navKey = GlobalKey<NavigatorState>();
      // Runs before the banner's own didPush post-frame callback (registered
      // earlier), so the route is already on top when that callback fires.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        navKey.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('2')),
          ),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [adRouteObserver],
          home: Scaffold(body: Column(children: [const BannerAdWidget()])),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('2'), findsOneWidget, reason: 'precondition: covered');

      navKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(const ValueKey('fake-banner-view')),
        findsOneWidget,
        reason:
            'a stale didPush callback must not raise the flag while the '
            'route is covered, or didPopNext no-ops and the banner stays blank',
      );
      await tester.pump(const Duration(milliseconds: 2500));
    },
  );

  testWidgets(
    'banner loaded under AdMob is torn down when a route is pushed over it, '
    'even if it was mounted before init',
    (tester) async {
      final adapter = _BannerCountingAdapter();
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
      AdManager().debugConnectivityReady = false;
      AdManager().debugConnectivityChanged(true);

      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [adRouteObserver],
          home: Scaffold(body: Column(children: [const BannerAdWidget()])),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // init completes AFTER the mount: the widget has only ever seen "no config"
      AdManager().debugVipManager = _FakeVip(false);
      AdManager().debugConfig = _config;
      AdManager().debugSetAdapter(adapter);
      AdManager().initRevision.value++;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('fake-banner-view')),
        findsOneWidget,
        reason: 'precondition: banner is live',
      );
      final disposedBefore = adapter.disposeBannerCalls;

      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('2')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        adapter.disposeBannerCalls,
        greaterThan(disposedBefore),
        reason:
            'AdMob has no pause API: a covered banner must be disposed so '
            'its native refresh timer stops (Round-29 policy rule)',
      );
      await tester.pump(const Duration(milliseconds: 2500));
    },
  );
}
