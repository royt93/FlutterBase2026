// T201 — InlineAdController wired into the REAL BannerAdWidget/MrecAdWidget/
// NativeAdWidget states (not the fake target from
// inline_ad_controller_test.dart): attach on mount, detach on dispose,
// surviving a rebuild, moving to a new controller instance mid-life, and
// refresh()/pause()/resume() actually calling into the widget's own
// existing gated dispose/reload path (never a shortcut around it).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  final Map<Object, AdSlot> bannerSlotsByKey = {};
  final Map<Object, BannerListenables> bannerListenablesByKey = {};
  int loadBannerCalls = 0;
  int disposeCalls = 0;

  @override
  AdSlot bannerSlot(Object key) =>
      bannerSlotsByKey.putIfAbsent(key, () => AdSlot(type: AdSlotType.banner));
  @override
  Iterable<AdSlot> get bannerSlots => bannerSlotsByKey.values;
  @override
  BannerListenables banner(Object key) => bannerListenablesByKey.putIfAbsent(
      key,
      () => BannerListenables(
            isLoaded: ValueNotifier<bool>(false),
            hasError: ValueNotifier<bool>(false),
            adSize: ValueNotifier<Size?>(null),
            autoRefreshEnabled: ValueNotifier<bool>(true),
            visible: ValueNotifier<bool>(true),
          ));
  @override
  void disposeBannerInstance(Object key) {
    disposeCalls++;
    bannerSlotsByKey.remove(key);
    bannerListenablesByKey.remove(key);
  }

  @override
  String get tag => 'counting';
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
  void applyConsent(AdConsent consent) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MrecCountingAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;
  final Map<Object, AdSlot> mrecSlotsByKey = {};
  final Map<Object, BannerListenables> mrecListenablesByKey = {};
  int loadMrecCalls = 0;
  int disposeCalls = 0;

  @override
  AdSlot mrecSlot(Object key) =>
      mrecSlotsByKey.putIfAbsent(key, () => AdSlot(type: AdSlotType.mrec));
  @override
  Iterable<AdSlot> get mrecSlots => mrecSlotsByKey.values;
  @override
  BannerListenables mrec(Object key) => mrecListenablesByKey.putIfAbsent(
      key,
      () => BannerListenables(
            isLoaded: ValueNotifier<bool>(false),
            hasError: ValueNotifier<bool>(false),
            adSize: ValueNotifier<Size?>(null),
            autoRefreshEnabled: ValueNotifier<bool>(true),
            visible: ValueNotifier<bool>(true),
          ));
  @override
  void disposeMrecInstance(Object key) {
    disposeCalls++;
    mrecSlotsByKey.remove(key);
    mrecListenablesByKey.remove(key);
  }

  @override
  String get tag => 'counting';
  @override
  Future<void> loadMrecIfNeeded(Object key, double widthPx) async =>
      loadMrecCalls++;
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Widget? buildAdmobMrecView(Object key) => null;
  @override
  void applyConsent(AdConsent consent) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NativeCountingAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;
  final AdSlot _mrecSlot = AdSlot(type: AdSlotType.mrec);
  @override
  AdSlot mrecSlot(Object key) => _mrecSlot;
  final Map<Object, AdSlot> nativeSlotsByKey = {};
  final Map<Object, BannerListenables> nativeListenablesByKey = {};
  int loadNativeCalls = 0;
  int disposeCalls = 0;
  final BannerListenables _mrec = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );

  @override
  AdSlot nativeSlot(Object key) =>
      nativeSlotsByKey.putIfAbsent(key, () => AdSlot(type: AdSlotType.native));
  @override
  BannerListenables native(Object key) => nativeListenablesByKey.putIfAbsent(
      key,
      () => BannerListenables(
            isLoaded: ValueNotifier<bool>(false),
            hasError: ValueNotifier<bool>(false),
            adSize: ValueNotifier<Size?>(null),
            autoRefreshEnabled: ValueNotifier<bool>(true),
            visible: ValueNotifier<bool>(true),
          ));
  @override
  void disposeNativeInstance(Object key) {
    disposeCalls++;
    nativeSlotsByKey.remove(key);
    nativeListenablesByKey.remove(key);
  }

  @override
  String get tag => 'counting';
  @override
  Future<void> preloadNative(Object key,
      {TemplateType templateType = TemplateType.medium}) async {
    loadNativeCalls++;
  }
  @override
  Widget? buildAdmobNativeView(Object key) => null;
  @override
  String? get appLovinNativeId => 'native-id';
  @override
  BannerListenables mrec(Object key) => _mrec;
  @override
  Future<void> loadMrecIfNeeded(Object key, double widthPx) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Widget? buildAdmobMrecView(Object key) => null;
  @override
  void applyConsent(AdConsent consent) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: Center(child: child)),
      );

  group('InlineAdController — constructor mutual exclusion', () {
    test('BannerAdWidget: passing both active and controller asserts', () {
      final controller = InlineAdController();
      expect(
          () => BannerAdWidget(active: true, controller: controller),
          throwsAssertionError);
      controller.dispose();
    });

    test('MrecAdWidget: passing both active and controller asserts', () {
      final controller = InlineAdController();
      expect(
          () => MrecAdWidget(active: true, controller: controller),
          throwsAssertionError);
      controller.dispose();
    });

    test('NativeAdWidget: passing active: false with controller asserts',
        () {
      final controller = InlineAdController();
      expect(
          () => NativeAdWidget(active: false, controller: controller),
          throwsAssertionError);
      controller.dispose();
    });
  });

  group('BannerAdWidget + InlineAdController', () {
    late _BannerCountingAdapter adapter;
    late InlineAdController controller;

    setUp(() {
      adapter = _BannerCountingAdapter();
      controller = InlineAdController();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      controller.dispose();
    });

    testWidgets('attaches on mount and detaches on dispose', (tester) async {
      expect(controller.isAttached, isFalse);

      await tester.pumpWidget(host(BannerAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isAttached, isTrue);
      expect(controller.status, InlineAdControllerStatus.active);

      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump();
      expect(controller.isAttached, isFalse);
      expect(controller.status, InlineAdControllerStatus.detached);
    });

    testWidgets('rebuilding with the same controller instance stays '
        'attached, no assertion error', (tester) async {
      await tester.pumpWidget(host(BannerAdWidget(
          key: const ValueKey('b'), controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isAttached, isTrue);

      // Same key, same controller, different (unrelated) field — a real
      // rebuild of the same Element, not a remount.
      await tester.pumpWidget(host(BannerAdWidget(
          key: const ValueKey('b'),
          controller: controller,
          placement: const AdPlacement.custom('t201'))));
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.isAttached, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('swapping to a new controller mid-life detaches the old '
        'one and attaches the new one', (tester) async {
      final secondController = InlineAdController();
      addTearDown(secondController.dispose);

      await tester.pumpWidget(host(BannerAdWidget(
          key: const ValueKey('b'), controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isAttached, isTrue);

      await tester.pumpWidget(host(BannerAdWidget(
          key: const ValueKey('b'), controller: secondController)));
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.isAttached, isFalse,
          reason: 'the old controller must be released, not left dangling');
      expect(secondController.isAttached, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh() reloads through the same cooldown gate — '
        'skipped while in cooldown, applied once reset', (tester) async {
      await tester.pumpWidget(host(BannerAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);

      // Still inside the cooldown window from the initial load.
      controller.refresh();
      await tester.pump();
      expect(adapter.disposeCalls, 0,
          reason: 'a refresh during cooldown must be skipped, not forced');
      expect(adapter.loadBannerCalls, 1);

      AdManager().debugResetBannerCooldown();
      controller.refresh();
      await tester.pump();
      expect(adapter.disposeCalls, 1);
      expect(adapter.loadBannerCalls, 2);
    });

    testWidgets('pause() disposes the live instance; resume() reloads it',
        (tester) async {
      await tester.pumpWidget(host(BannerAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);

      controller.pause();
      await tester.pump();
      expect(controller.status, InlineAdControllerStatus.paused);
      expect(adapter.disposeCalls, 1);

      controller.resume();
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.status, InlineAdControllerStatus.active);
      expect(adapter.loadBannerCalls, 2);
      expect(tester.takeException(), isNull);
    });

    // T201 — the exact gap this class's own doc comment on didPopNext
    // fixes: without it, returning to this route (a real, common
    // "background/foreground"-shaped navigation) would silently reload a
    // banner the host explicitly paused via the controller.
    testWidgets(
        'a route push+pop while paused via the controller does NOT '
        'silently reload it — it stays paused until resume() is called',
        (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: BannerAdWidget(controller: controller)),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);

      controller.pause();
      await tester.pump();
      expect(adapter.disposeCalls, 1);

      navKey.currentState!.push(
        MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('top'))),
      );
      await tester.pumpAndSettle();
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(controller.status, InlineAdControllerStatus.paused,
          reason: 'the route round trip must not have resumed it');
      expect(adapter.loadBannerCalls, 1,
          reason: 'no reload must have happened while still paused');

      AdManager().debugResetBannerCooldown();
      controller.resume();
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 2);
      expect(tester.takeException(), isNull);

      // Unmount cleanly before the next test's setUp swaps the adapter out
      // — otherwise this widget's dispose() (still pending, since it's on
      // a pushed Navigator's stack) fires lazily against whatever adapter
      // is live by then.
      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump();
    });
  });

  group('MrecAdWidget + InlineAdController', () {
    late _MrecCountingAdapter adapter;
    late InlineAdController controller;

    setUp(() {
      adapter = _MrecCountingAdapter();
      controller = InlineAdController();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      controller.dispose();
    });

    testWidgets('attaches on mount and detaches on dispose', (tester) async {
      await tester.pumpWidget(host(MrecAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isAttached, isTrue);

      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump();
      expect(controller.isAttached, isFalse);
    });

    testWidgets('refresh() reloads through the same cooldown gate',
        (tester) async {
      await tester.pumpWidget(host(MrecAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadMrecCalls, 1);

      AdManager().debugResetMrecCooldown();
      controller.refresh();
      await tester.pump();
      expect(adapter.disposeCalls, 1);
      expect(adapter.loadMrecCalls, 2);
    });

    testWidgets('pause()/resume() dispose and reload the live instance',
        (tester) async {
      await tester.pumpWidget(host(MrecAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));

      controller.pause();
      await tester.pump();
      expect(adapter.disposeCalls, 1);

      controller.resume();
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadMrecCalls, 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('NativeAdWidget + InlineAdController', () {
    late _NativeCountingAdapter adapter;
    late InlineAdController controller;

    setUp(() {
      adapter = _NativeCountingAdapter();
      controller = InlineAdController();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      controller.dispose();
    });

    testWidgets('attaches on mount and detaches on dispose', (tester) async {
      await tester.pumpWidget(host(NativeAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isAttached, isTrue);

      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump();
      expect(controller.isAttached, isFalse);
    });

    testWidgets(
        'pause() disposes the live instance (no ticker to merely '
        'suspend); resume() reloads it', (tester) async {
      await tester.pumpWidget(host(NativeAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 1);

      controller.pause();
      await tester.pump();
      expect(controller.status, InlineAdControllerStatus.paused);
      expect(adapter.disposeCalls, 1);

      controller.resume();
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.status, InlineAdControllerStatus.active);
      expect(adapter.loadNativeCalls, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refresh() reloads through the same cooldown gate',
        (tester) async {
      await tester.pumpWidget(host(NativeAdWidget(controller: controller)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 1);

      AdManager().debugResetNativeCooldown();
      controller.refresh();
      await tester.pump();
      expect(adapter.disposeCalls, 1);
      expect(adapter.loadNativeCalls, 2);
    });
  });
}
