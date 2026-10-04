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

  int disposeCalls = 0;

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

  // Round-39 audit fix (MAJOR) — same `active` param, same gap, as
  // BannerAdWidget (see its own class doc comment for the full reasoning:
  // a bare IndexedStack tab needs this wired manually — neither TickerMode
  // nor the automatic VisibilityDetector can see it going offstage).
  testWidgets(
      'the manual active:false override pauses it, active:true resumes it',
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

    final active = ValueNotifier<bool>(true);
    await tester.pumpWidget(host(ValueListenableBuilder<bool>(
      valueListenable: active,
      builder: (context, isActive, _) => MrecAdWidget(active: isActive),
    )));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(adapter.loadMrecCalls, 1);
    expect(adapter.disposeCalls, 0);

    active.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.disposeCalls, 1,
        reason: 'active:false must dispose the MREC instance');

    active.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadMrecCalls, 2, reason: 'active:true must resume it');
  });

  // Round-39 audit re-review (MAJOR, independent Gemini pass) — mirrors
  // BannerAdWidget's matching test: mounting directly with active: false
  // (the actual IndexedStack use case, not just flipping it after mount)
  // was never covered and was in fact broken.
  testWidgets(
      'mounting directly with active:false never loads, flipping to true '
      'afterward loads it for the first time', (tester) async {
    final adapter = _MrecCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetMrecCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    final active = ValueNotifier<bool>(false);
    await tester.pumpWidget(host(ValueListenableBuilder<bool>(
      valueListenable: active,
      builder: (context, isActive, _) => MrecAdWidget(active: isActive),
    )));
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadMrecCalls, 0,
        reason: 'a widget that starts inactive must never load an ad it '
            'was never allowed to show in the first place');

    active.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadMrecCalls, 1,
        reason: 'switching to active must load it for the first time');
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

  group('T240 — house ad fallback on no-fill/offline', () {
    late _MrecCountingAdapter adapter;

    setUp(() {
      adapter = _MrecCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugCanRequestAds = true;
      AdManager().debugVipManager = null;
      AdManager().debugConnectivityChanged(true);
    });

    var tapped = 0;
    HouseAdItem item() {
      tapped = 0;
      return HouseAdItem(
        assetPath: 'assets/house_ad.png',
        title: 'MREC house fallback',
        subtitle: 'Local content',
        onTap: () => tapped++,
      );
    }

    test('houseAdDelay defaults to 10 seconds', () {
      const widget = MrecAdWidget();
      expect(widget.houseAdDelay, const Duration(seconds: 10));
      expect(widget.houseAd, isNull);
    });

    testWidgets(
        'no houseAd configured: no-fill stays byte-compatible blank forever',
        (tester) async {
      await tester.pumpWidget(host(const MrecAdWidget(active: true)));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump(const Duration(seconds: 15));

      expect(find.text('MREC house fallback'), findsNothing);
      expect(tester.getSize(find.byType(MrecAdWidget)).height, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'configured no-fill past delay renders fallback, tap fires, and no '
        'AdEvent is emitted', (tester) async {
      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);
      addTearDown(sub.cancel);

      await tester.pumpWidget(host(MrecAdWidget(
        active: true,
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 2),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('MREC house fallback'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      expect(find.text('MREC house fallback'), findsOneWidget);
      expect(tester.getSize(find.byType(MrecAdWidget)).height, greaterThan(0));

      await tester.tap(find.text('MREC house fallback'));
      expect(tapped, 1);
      expect(events, isEmpty,
          reason: 'house content must not synthesize provider ad events');
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline past delay renders fallback without requesting fill',
        (tester) async {
      AdManager().debugConnectivityChanged(false);

      await tester.pumpWidget(host(MrecAdWidget(
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 2),
      )));
      await tester.pump(const Duration(seconds: 3));

      expect(find.text('MREC house fallback'), findsOneWidget);
      expect(adapter.loadMrecCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('real MREC before delay cancels pending fallback', (tester) async {
      await tester.pumpWidget(host(MrecAdWidget(
        active: true,
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 2),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      listenables.hasError.value = false;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(300, 250);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('MREC house fallback'), findsNothing);
      expect(find.text('Ad'), findsOneWidget,
          reason: 'successful provider content replaces the blank branch');
      expect(tester.takeException(), isNull);
    });

    testWidgets('real MREC returning after fallback removes it', (tester) async {
      await tester.pumpWidget(host(MrecAdWidget(
        active: true,
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 1),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('MREC house fallback'), findsOneWidget);

      listenables.hasError.value = false;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(300, 250);
      await tester.pump();

      expect(find.text('MREC house fallback'), findsNothing);
      expect(find.text('Ad'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposing while fallback timer is pending is safe',
        (tester) async {
      await tester.pumpWidget(host(MrecAdWidget(
        active: true,
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 5),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.hasError.value = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump(const Duration(seconds: 6));

      expect(find.byType(MrecAdWidget), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'visibility pause/resume while offline preserves one fallback timer',
        (tester) async {
      AdManager().debugConnectivityChanged(false);
      final active = ValueNotifier<bool>(true);
      addTearDown(active.dispose);

      await tester.pumpWidget(host(ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (_, value, _) => MrecAdWidget(
          active: value,
          houseAd: item(),
          houseAdDelay: const Duration(seconds: 2),
        ),
      )));
      await tester.pump(const Duration(seconds: 1));
      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('MREC house fallback'), findsOneWidget,
          reason: 'pause/resume rebuilds must not duplicate or reset timer');
      await tester.tap(find.text('MREC house fallback'));
      expect(tapped, 1);
      expect(adapter.loadMrecCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('VIP suppresses fallback but consent-blocked state matches Banner',
        (tester) async {
      AdManager().debugCanRequestAds = false;
      await tester.pumpWidget(host(MrecAdWidget(
        houseAd: item(),
        houseAdDelay: Duration.zero,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('MREC house fallback'), findsOneWidget,
          reason: 'Banner also permits local fallback before consent');
      expect(adapter.loadMrecCalls, 0);

      AdManager().debugVipManager = _FakeVip(true);
      AdManager().initRevision.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('MREC house fallback'), findsNothing,
          reason: 'VIP suppression remains stronger than local fallback');
      expect(tester.getSize(find.byType(MrecAdWidget)).height, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('T231 Flight Recorder visibility evidence', () {
    testWidgets(
        'visible transition records viewability and pixel bounds when '
        'enabled', (tester) async {
      final adapter = _MrecCountingAdapter();
      final recorder = AdFlightRecorder();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      AdManager().enableFlightRecorder(recorder);
      addTearDown(() {
        AdManager().disableFlightRecorder();
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(host(const MrecAdWidget(placement: AdPlacement.home)));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.entries, isNotEmpty);
      final visible =
          recorder.entries.firstWhere((e) => e.label == 'mrecVisible');
      expect(visible.slotType, 'mrec');
      expect(visible.placement, 'home');
      expect(visible.viewabilityFraction, greaterThan(0));
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    testWidgets('T241: unmount while visible records exactly one mrecHidden',
        (tester) async {
      final adapter = _MrecCountingAdapter();
      final recorder = AdFlightRecorder();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      AdManager().enableFlightRecorder(recorder);
      addTearDown(() {
        AdManager().disableFlightRecorder();
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(
          host(const MrecAdWidget(placement: AdPlacement.home)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(recorder.entries.where((e) => e.label == 'mrecVisible'),
          hasLength(1));

      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.entries.where((e) => e.label == 'mrecHidden'),
          hasLength(1),
          reason: 'dispose closes the visible evidence interval exactly once');
      expect(recorder.entries.last.label, 'mrecHidden');
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'unmounting a never-visible mrec does not create an orphan hidden '
        'entry or throw', (tester) async {
      final adapter = _MrecCountingAdapter();
      final recorder = AdFlightRecorder();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      AdManager().enableFlightRecorder(recorder);
      addTearDown(() {
        AdManager().disableFlightRecorder();
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(
          host(const MrecAdWidget(placement: AdPlacement.home)));
      // Unmount immediately, before pumping the visibility callback.
      await tester.pumpWidget(host(const SizedBox()));
      final countAfterDispose = recorder.entries.length;
      await tester.pump(const Duration(milliseconds: 100));

      expect(recorder.entries, hasLength(countAfterDispose));
      expect(recorder.entries.where((e) => e.label == 'mrecHidden'), isEmpty,
          reason: 'never-visible unmount must not create an orphan close');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'disabled mode records nothing and leaves existing behavior '
        'unchanged', (tester) async {
      final adapter = _MrecCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      AdManager().disableFlightRecorder();
      addTearDown(() {
        AdManager().disableFlightRecorder();
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(host(const MrecAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadMrecCalls, 1,
          reason: 'default-off recorder must not change mrec loading');
      expect(AdManager().flightRecorder, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'T240/T237 — house ad visible with recorder enabled emits no '
        'provider mrec evidence', (tester) async {
      final adapter = _MrecCountingAdapter();
      final recorder = AdFlightRecorder();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      AdManager().enableFlightRecorder(recorder);
      addTearDown(() {
        AdManager().disableFlightRecorder();
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      final controller = ScrollController();
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(
          body: SingleChildScrollView(
            controller: controller,
            child: Column(children: [
              MrecAdWidget(
                active: true,
                houseAd: HouseAdItem(
                  assetPath: 'assets/house_ad.png',
                  title: 'MREC fallback evidence',
                ),
                houseAdDelay: Duration.zero,
              ),
              const SizedBox(height: 1000),
            ]),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('MREC fallback evidence'), findsOneWidget,
          reason: 'precondition: only the local house fallback is rendered');
      recorder.clear();

      // Real VisibilityDetector transitions while the fallback remains the
      // only painted content — must never become provider evidence.
      controller.jumpTo(500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      controller.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('MREC fallback evidence'), findsOneWidget);
      expect(
        recorder.entries.where((entry) =>
            entry.providerTag == adapter.tag &&
            (entry.label == 'mrecVisible' || entry.label == 'mrecHidden')),
        isEmpty,
        reason: 'house fallback must never become provider impression evidence',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'T240 — real mrec displayed still records correct provider tag',
        (tester) async {
      final adapter = _MrecCountingAdapter();
      final recorder = AdFlightRecorder();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      AdManager().enableFlightRecorder(recorder);
      addTearDown(() {
        AdManager().disableFlightRecorder();
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(host(MrecAdWidget(
        houseAd: HouseAdItem(
          assetPath: 'assets/house_ad.png',
          title: 'MREC fallback evidence',
        ),
        houseAdDelay: const Duration(seconds: 10),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(300, 250);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('MREC fallback evidence'), findsNothing);
      final visible =
          recorder.entries.firstWhere((e) => e.label == 'mrecVisible');
      expect(visible.providerTag, adapter.tag,
          reason: 'real mrec evidence keeps the active provider tag');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'house ad visible with recorder disabled is unchanged and safe',
        (tester) async {
      final adapter = _MrecCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetMrecCooldown();
      AdManager().disableFlightRecorder();
      addTearDown(() {
        AdManager().disableFlightRecorder();
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(host(MrecAdWidget(
        active: true,
        houseAd: HouseAdItem(
          assetPath: 'assets/house_ad.png',
          title: 'MREC fallback evidence',
        ),
        houseAdDelay: Duration.zero,
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.mrecListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('MREC fallback evidence'), findsOneWidget);
      expect(AdManager().flightRecorder, isNull);
      expect(tester.takeException(), isNull);
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
