// Widget tests for MrecAdWidget — mirrors banner_ad_widget_test.dart's gating
// coverage (RouteAware plumbing is byte-identical to BannerAdWidget and is
// already exercised there; these tests focus on the MREC-specific wiring:
// AdManager().mrec* accessors, canLoadMrec()/recordMrecLoad(), and
// loadAdmobMrecIfNeeded).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  // T65 (phase 3) — keyed by widget instance, mirroring the real adapters.
  final Map<Object, AdSlot> mrecSlotsByKey = {};
  final Map<Object, BannerListenables> mrecListenablesByKey = {};
  int loadMrecCalls = 0;

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
  // No-ops so _retryRefillAds (fired on reconnect) doesn't hit noSuchMethod.
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
  Widget? buildAdmobMrecView(Object key) =>
      null; // placeholder path, no native view
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
    mrecId: 'ca-app-pub-3940256099942544/2247696110',
  ),
);

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('renders an empty box when the SDK is not initialised',
      (tester) async {
    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pumpAndSettle();

    expect(find.byType(MrecAdWidget), findsOneWidget);
    final size = tester.getSize(find.byType(MrecAdWidget));
    expect(size.height, 0,
        reason: 'uninitialised MREC must collapse to zero height');
  });

  // T57 — mirrors the same coverage added to banner_ad_widget_test.dart: a
  // MREC mounted on a route that's already current (never pushed) must still
  // render, since RouteObserver.subscribe() fires didPush() synchronously
  // regardless of whether the route was freshly pushed or already active
  // (flutter/lib/src/widgets/routes.dart RouteObserver.subscribe).
  testWidgets(
      'AdMob mrec mounted on an already-current route (never pushed) '
      'still renders the ad, not the placeholder', (tester) async {
    final adapter = _MrecCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetMrecCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    // T65: the widget only owns its (keyed) listenables once mounted —
    // simulate the load completing for its instance.
    final listenables = adapter.mrecListenablesByKey.values.single;
    listenables.isLoaded.value = true;
    listenables.visible.value = true;
    listenables.adSize.value = const Size(300, 250);
    await tester.pump();

    expect(find.text('Ad'), findsOneWidget,
        reason: 'a mrec on an already-current route must render '
            'immediately instead of waiting for a didPush() that will '
            'never fire');
    expect(tester.takeException(), isNull);
  });

  testWidgets('mounts and disposes without throwing', (tester) async {
    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pumpAndSettle();

    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();

    expect(find.byType(MrecAdWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // T65 — before the keyed refactor, two simultaneous MrecAdWidgets on
  // AdMob shared one adapter-level BannerAd/AdSlot/BannerListenables bundle
  // (MREC reuses banner's native BannerAd API) and would crash the same way.
  testWidgets(
      'two simultaneous MrecAdWidgets on AdMob get independent slots, '
      'no crash', (tester) async {
    final adapter = _MrecCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetMrecCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const SingleChildScrollView(
      child: Column(
        children: [MrecAdWidget(), MrecAdWidget()],
      ),
    )));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MrecAdWidget), findsNWidgets(2));
    expect(adapter.mrecListenablesByKey.length, 2,
        reason:
            'each widget instance must get its own BannerListenables, not share one');
    expect(adapter.loadMrecCalls, 2,
        reason: 'each widget triggers its own load');
    expect(tester.takeException(), isNull);

    // One instance finishing loading must not affect the other.
    adapter.mrecListenablesByKey.values.first.isLoaded.value = true;
    await tester.pump();
    final loadedStates =
        adapter.mrecListenablesByKey.values.map((l) => l.isLoaded.value);
    expect(loadedStates, containsAllInOrder([true, false]),
        reason: 'flipping one instance loaded must not flip the other');
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives a route push and pop on top of it', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [adRouteObserver],
      home: const Scaffold(body: MrecAdWidget()),
    ));
    await tester.pumpAndSettle();

    navKey.currentState!.push(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('top'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('top'), findsOneWidget);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(MrecAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated rebuilds trigger exactly one MREC load',
      (tester) async {
    final adapter = _MrecCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetMrecCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 0; i < 5; i++) {
      AdManager().initRevision.value = AdManager().initRevision.value + 1;
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadMrecCalls, 1,
        reason: 'MREC loads once despite repeated rebuilds');
    expect(tester.takeException(), isNull);
  });

  testWidgets('MREC collapses offline and reloads on reconnect',
      (tester) async {
    final adapter = _MrecCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetMrecCooldown();
    AdManager().debugReconnectDebounce = Duration.zero;
    AdManager().debugConnectivityChanged(false); // go offline
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugConnectivityChanged(true);
    });

    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadMrecCalls, 0, reason: 'offline → no MREC load');

    AdManager().debugConnectivityChanged(true);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    await tester.pump();
    expect(adapter.loadMrecCalls, 1, reason: 'reconnect → MREC reloads');
    expect(tester.takeException(), isNull);
  });

  testWidgets('VIP active → MREC collapses to empty box, never loads',
      (tester) async {
    final adapter = _MrecCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetMrecCooldown();
    AdManager().debugVipManager = _FakeVip(true);
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
    });

    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadMrecCalls, 0, reason: 'VIP member → no MREC load');
    final size = tester.getSize(find.byType(MrecAdWidget));
    expect(size.height, 0,
        reason: 'VIP member must collapse to zero height, like uninitialised');
    expect(tester.takeException(), isNull);
  });

  group('T101 — consent gate closes/reopens mid-session (mrec)', () {
    testWidgets(
        'consent revoked while mounted disposes the instance and collapses; '
        'reopening reloads a fresh one', (tester) async {
      final adapter = _MrecCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        AdManager().debugCanRequestAds = true;
      });

      await tester.pumpWidget(host(const MrecAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadMrecCalls, 1);
      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(300, 250);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(MrecAdWidget)).height, greaterThan(0),
          reason: 'loaded mrec is visible before consent is revoked');

      AdManager().debugCanRequestAds = false;
      await tester.pumpAndSettle();

      expect(adapter.mrecListenablesByKey, isEmpty,
          reason: 'disposeMrecInstance must run as soon as the gate closes');
      expect(tester.getSize(find.byType(MrecAdWidget)).height, 0,
          reason: 'mounted mrec collapses immediately on consent revoke, '
              'not just when it happens to unmount');

      // The per-widget 30s throttle is keyed by `this` and survived the
      // dispose above (it isn't part of consent state) — reset it here the
      // same way a real 30s wait would, so the reload assertion below is
      // isolated to the consent-gate behavior under test.
      AdManager().debugResetMrecCooldown();
      AdManager().debugCanRequestAds = true;
      // Not pumpAndSettle: the reloaded mrec goes back through the
      // placeholder shimmer, which animates forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadMrecCalls, 2,
          reason: 'reopening the gate re-triggers a fresh load');
    });
  });

  group('T107 — placement', () {
    test('defaults to AdPlacement.unspecified', () {
      const widget = MrecAdWidget();
      expect(widget.placement, AdPlacement.unspecified);
    });

    test('accepts a custom placement', () {
      const widget = MrecAdWidget(placement: AdPlacement.shop);
      expect(widget.placement, AdPlacement.shop);
    });
  });
}

/// Fake VipManager whose `isActive` is fixed — the only member AdManager
/// reads for gating (`_isVipMember => _vipManager?.isActive ?? false`).
class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;

  @override
  bool get isActive => _active;

  @override
  ValueListenable<bool> get activeListenable => ValueNotifier<bool>(_active);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
