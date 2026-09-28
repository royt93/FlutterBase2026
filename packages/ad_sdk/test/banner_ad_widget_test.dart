// Widget tests for BannerAdWidget.
//
// These run WITHOUT a real ad provider: in the test environment the
// AdManager singleton is never `initialize()`d, so `isInitialised` is false and
// the widget must collapse to an empty box (never paint an impression for an
// uninitialised / VIP user). We assert that safe-default rendering plus a clean
// mount → route → dispose lifecycle (RouteAware subscribe/unsubscribe must not
// throw).
//
// What's covered:
//   • Renders an empty (zero-size) box when the SDK is not initialised.
//   • Mounts and disposes without throwing (RouteAware + ValueNotifier teardown).
//   • Survives a route push/pop on top of it (didPushNext/didPopNext).
//   • Does not paint an AppLovin/AdMob platform view when uninitialised.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart'
    hide BannerErrorSelfCollapse;
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart'
    show BannerErrorSelfCollapse;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// AdMob-provider fake that counts banner loads, for the T12 rebuild test.
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
  // T65 (phase 2) — keyed by widget instance, mirroring the real adapters.
  final Map<Object, AdSlot> bannerSlotsByKey = {};
  final Map<Object, BannerListenables> bannerListenablesByKey = {};
  int loadBannerCalls = 0;
  int preloadBannerCalls = 0;
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
  double? lastWidthPx;
  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {
    loadBannerCalls++;
    lastWidthPx = widthPx;
  }
  @override
  Future<void> preloadBanner(Object key) async => preloadBannerCalls++;
  @override
  Future<void> preloadMrec(Object key) async {}
  // No-ops so _retryRefillAds (fired on reconnect) doesn't hit noSuchMethod.
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
      null; // placeholder path, no native view
  @override
  ValueListenable<Object?> appLovinBannerAdViewId(Object key) =>
      const _NullObjectListenable();
  @override
  void applyConsent(AdConsent consent) {}
  // AppLovin (non-AdMob) branch of didPush/didPushNext/didPopNext calls this
  // unconditionally instead of dispose/reload — needed for the T226 AppLovin
  // group below.
  @override
  void setBannerRoutePaused(Object key, bool paused) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Constant-null listenable for `appLovinBannerAdViewId` — the test only
/// asserts on preload/dispose counts, never renders a real `MaxAdView`.
class _NullObjectListenable extends ValueListenable<Object?> {
  const _NullObjectListenable();
  @override
  Object? get value => null;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _CollapsingBannerCountingAdapter extends _BannerCountingAdapter
    implements BannerErrorSelfCollapse {
  @override
  bool get collapsesBannerOnError => true;
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

/// T226 — same shape as `_admobConfig` but driving the AppLovin branch of
/// `_initBanner` (which calls `preloadBanner` and deliberately skips the
/// width-observer reload — `MaxAdView` resizes natively).
final _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'test-sdk-key',
    bannerId: 'test-banner-id',
    interstitialId: 'test-interstitial-id',
    rewardedId: 'test-rewarded-id',
    appOpenId: 'test-appopen-id',
  ),
);

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('renders an empty box when the SDK is not initialised',
      (tester) async {
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pumpAndSettle();

    // The widget tree contains the BannerAdWidget but it must not paint a
    // banner surface — a SizedBox.shrink is rendered as the safe default.
    expect(find.byType(BannerAdWidget), findsOneWidget);
    final size = tester.getSize(find.byType(BannerAdWidget));
    expect(size.height, 0,
        reason: 'uninitialised banner must collapse to zero height');
  });

  testWidgets('mounts and disposes without throwing', (tester) async {
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pumpAndSettle();

    // Replace the widget tree → triggers _BannerAdWidgetState.dispose
    // (RouteAware unsubscribe + 3 ValueNotifier disposals).
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();

    expect(find.byType(BannerAdWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // T65 — before the keyed refactor, two simultaneous BannerAdWidgets on
  // AdMob shared one adapter-level BannerAd/AdSlot/BannerListenables bundle:
  // google_mobile_ads would throw "This AdWidget is already in the Widget
  // tree" once both mounted the same underlying ad. This fake adapter
  // doesn't reproduce that exact platform-channel crash, but it does prove
  // the widget layer now generates independent keys and independent state.
  testWidgets(
      'two simultaneous BannerAdWidgets on AdMob get independent slots, '
      'no crash', (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const SingleChildScrollView(
      child: Column(
        children: [BannerAdWidget(), BannerAdWidget()],
      ),
    )));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(BannerAdWidget), findsNWidgets(2));
    expect(adapter.bannerListenablesByKey.length, 2,
        reason:
            'each widget instance must get its own BannerListenables, not share one');
    expect(adapter.loadBannerCalls, 2,
        reason: 'each widget triggers its own load');
    expect(tester.takeException(), isNull);

    // One instance finishing loading must not affect the other.
    adapter.bannerListenablesByKey.values.first.isLoaded.value = true;
    await tester.pump();
    final loadedStates =
        adapter.bannerListenablesByKey.values.map((l) => l.isLoaded.value);
    expect(loadedStates, containsAllInOrder([true, false]),
        reason: 'flipping one instance loaded must not flip the other');
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives a route push and pop on top of it', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [adRouteObserver],
      home: const Scaffold(body: BannerAdWidget()),
    ));
    await tester.pumpAndSettle();

    // Push a route on top → BannerAdWidget receives didPushNext.
    navKey.currentState!.push(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('top'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('top'), findsOneWidget);

    // Pop back → didPopNext. No banner should be painted, no exception.
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // T12 — repeated rebuilds must not stack banner loads. The _initScheduled
  // guard + _allowed + cooldown together ensure a single load.
  testWidgets('repeated rebuilds trigger exactly one banner load',
      (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig; // isInitialised + AdMob provider
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const BannerAdWidget()));
    // Not pumpAndSettle: the placeholder shimmer animates forever.
    await tester.pump(const Duration(milliseconds: 50));

    // Force several rebuilds via initRevision bumps.
    for (var i = 0; i < 5; i++) {
      AdManager().initRevision.value = AdManager().initRevision.value + 1;
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadBannerCalls, 1,
        reason: 'banner loads once despite repeated rebuilds');
    expect(tester.takeException(), isNull);
  });

  // M1 (2026-08-22 audit) — consent_withdrawal_discard_test.dart only ever
  // asserted that AdManager.personalisationRevision's counter increments; no
  // test drove the actual listener in this file that the fix lives in. Before
  // the fix, withdrawing personalisation left an already-loaded, personalised
  // banner mounted and auto-refreshing with no re-verified consent basis —
  // `canRequestAdsListenable` doesn't fire for this (the gate itself stays
  // open), so nothing else in this widget would have dropped it.
  testWidgets(
      'withdrawing personalisation drops the mounted, loaded banner instance',
      (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 1);
    final key = adapter.bannerListenablesByKey.keys.single;
    adapter.bannerListenablesByKey[key]!.isLoaded.value = true;
    await tester.pump();

    AdManager().personalisationRevision.value =
        AdManager().personalisationRevision.value + 1;
    await tester.pump();

    expect(adapter.bannerListenablesByKey.containsKey(key), isFalse,
        reason: 'M1: the real widget listener must dispose the mounted '
            'instance — the personalised ad it was showing has no verified '
            'consent basis any more');
    expect(tester.takeException(), isNull);

    // Re-init runs on the next frame (gate is still open) — a fresh, un-
    // personalised load must replace the dropped one, not leave the widget
    // permanently blank.
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 2,
        reason: 'a fresh load must replace the dropped instance');
  });

  // T14 — the banner's own enclosing route can change (e.g. replaced by a
  // new route, or the banner subtree is re-parented under a different
  // route/dialog). Previously `_routeSubscribed` was a one-shot latch: once
  // true it never re-subscribed, so a route-replace event stopped delivering
  // RouteAware callbacks (didPush/didPushNext/didPopNext) to the banner
  // entirely — it kept listening to the old, now-detached route.
  testWidgets(
      'route replace re-subscribes RouteAware to the new route (push→pop→push)',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [adRouteObserver],
      home: const Scaffold(body: BannerAdWidget()),
    ));
    await tester.pumpAndSettle();

    // Push a new route whose body is ALSO a BannerAdWidget — simulates the
    // "banner on a different route" scenario from the acceptance criteria.
    // Its RouteAware subscription must bind to this new route, not stay
    // latched to (or leak from) the first one.
    //
    // Not awaited: Navigator.push()'s returned Future only completes when
    // the route is later popped (it resolves with the pop result), so
    // awaiting it here would deadlock the test forever.
    navKey.currentState!.push(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: BannerAdWidget())),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsOneWidget,
        reason: 'first banner is now covered; only the pushed one is live');
    expect(tester.takeException(), isNull);

    // Pop back to the first route.
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Push again — a fresh BannerAdWidget instance on a fresh route. If the
    // previous instance's dispose() didn't balance its subscribe (or a new
    // instance's didChangeDependencies failed to (re-)subscribe), this would
    // either throw or leave RouteAware callbacks silently undelivered.
    // Not awaited — see note above.
    navKey.currentState!.push(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: BannerAdWidget())),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // T23 (leak-audit round) — rapid push/pop/push/pop/push/pop of a banner
  // screen within a single frame budget (no pumpAndSettle between steps,
  // unlike the T14 test above). Guards against a duplicate banner load or an
  // orphaned RouteAware subscription piling up when navigation outruns the
  // post-frame callback that schedules _initBanner.
  testWidgets('rapid push/pop x3 does not stack banner loads or leak routes',
      (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [adRouteObserver],
      home: const Scaffold(body: BannerAdWidget()),
    ));
    await tester.pump(const Duration(milliseconds: 50)); // initial load settles

    for (var i = 0; i < 3; i++) {
      navKey.currentState!.push(
        MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: BannerAdWidget())),
      );
      await tester
          .pump(); // no settle — next push/pop fires before shimmer/animations finish
      navKey.currentState!.pop();
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull,
        reason:
            'no crash from stale RouteAware subscription or double dispose');
    // Base-route banner reloads at most once per pop-back (cooldown-gated);
    // it must never exceed a small bound — a leak would make this grow
    // unbounded with iteration count. Bound raised for the round-29 audit
    // fix: popping back onto the base route now actually reloads its
    // banner (previously it silently stayed on the stale pre-push
    // instance) — up to 3 more legitimate loads across these 3 iterations,
    // on top of the pushed route's own 3 loads and the 1 initial load.
    expect(adapter.loadBannerCalls, lessThanOrEqualTo(7),
        reason:
            'repeated rapid push/pop must not stack duplicate banner loads');
  });

  // T09 — offline: banner stays collapsed (no load, no shimmer); on reconnect
  // (T08 connectivity watch) it reloads automatically.
  testWidgets('banner collapses offline and reloads on reconnect',
      (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    AdManager().debugReconnectDebounce = Duration.zero;
    AdManager().debugConnectivityChanged(false); // go offline
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugConnectivityChanged(true);
    });

    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 0, reason: 'offline → no banner load');

    // Reconnect → connectivity watch (zero debounce) fires → refill + bump
    // initRevision → rebuild → post-frame _initBanner → load.
    AdManager().debugConnectivityChanged(true);
    await tester.pump(const Duration(milliseconds: 10)); // debounce timer fires
    await tester.pump(); // rebuild from initRevision bump
    await tester.pump(); // post-frame _initBanner runs
    expect(adapter.loadBannerCalls, 1, reason: 'reconnect → banner reloads');
    expect(tester.takeException(), isNull);
  });

  // isConnected pre-ready guard, banner leg: a banner mounted/loading during
  // the window before ConnectionNotifierTools.initialize() resolves must not
  // throw and must behave as if online (isConnected short-circuits to the
  // optimistic `_lastConnected` default of true) — reproduces the original
  // production race where preloadBanner()/loadBannerIfNeeded() could run
  // before _startConnectivityWatch's initialize() future settled.
  testWidgets('mounts and loads normally while connectivity is not yet ready',
      (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    AdManager().debugConnectivityReady = false;
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugConnectivityReady = false;
    });

    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadBannerCalls, 1,
        reason: 'pre-ready guard reads last-known (true) — banner loads '
            'exactly as it would once ready');
    expect(tester.takeException(), isNull);
  });

  // T57 — a banner mounted on a route that is ALREADY current (e.g. the
  // app's home/splash screen) never receives RouteAware's didPush(), because
  // the route was pushed by the Navigator before this widget existed to
  // subscribe to it. Previously `_admobIsTop` stayed false forever in that
  // case, so an AdMob banner on the home screen never painted — only the
  // permanently-collapsed placeholder branch.
  testWidgets(
      'AdMob banner mounted on an already-current route (never pushed) '
      'still renders the ad, not the placeholder', (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    // `host()` mounts BannerAdWidget directly as `home:` — never pushed via
    // Navigator, so didPush() never fires for it.
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    // T65: the widget only owns its (keyed) listenables once mounted —
    // simulate the load completing for its instance.
    final listenables = adapter.bannerListenablesByKey.values.single;
    listenables.isLoaded.value = true;
    listenables.visible.value = true;
    listenables.adSize.value = const Size(320, 50);
    await tester.pump();

    expect(find.text('Ad'), findsOneWidget,
        reason: 'a banner on an already-current route must render '
            'immediately instead of waiting for a didPush() that will '
            'never fire');
    expect(tester.takeException(), isNull);
  });

  // VIP-suppresses-all-ads contract, banner leg: a VIP member must never see
  // a banner load, even with an initialised adapter/config that would
  // otherwise load one for a non-VIP user (see `_isVipMember` gate in
  // BannerAdWidget, mirrors the interstitial/rewarded gates already covered
  // in ad_manager_core_test.dart's "VIP gating" group).
  testWidgets('VIP active → banner collapses to empty box, never loads',
      (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    AdManager().debugVipManager = _FakeVip(true);
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
    });

    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadBannerCalls, 0, reason: 'VIP member → no banner load');
    final size = tester.getSize(find.byType(BannerAdWidget));
    expect(size.height, 0,
        reason: 'VIP member must collapse to zero height, like uninitialised');
    expect(tester.takeException(), isNull);
  });

  // T91 — collapsing/expanding must animate (AnimatedSize), not jump
  // instantly, so the layout doesn't shift abruptly under surrounding
  // content when a banner errors out or a real ad becomes ready.
  testWidgets(
      'collapsing on a load error animates the height down instead of '
      'jumping straight to zero', (tester) async {
    final adapter = _CollapsingBannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    final listenables = adapter.bannerListenablesByKey.values.single;
    listenables.isLoaded.value = true;
    listenables.visible.value = true;
    listenables.adSize.value = const Size(320, 50);
    await tester.pumpAndSettle();

    final loadedHeight = tester.getSize(find.byType(BannerAdWidget)).height;
    expect(loadedHeight, greaterThan(0));

    // Simulate a load error collapsing the banner.
    listenables.hasError.value = true;
    listenables.isLoaded.value = false;
    await tester.pump(); // one frame in — animation just started
    await tester.pump(const Duration(milliseconds: 100)); // mid-animation

    final midHeight = tester.getSize(find.byType(BannerAdWidget)).height;
    expect(midHeight, greaterThan(0));
    expect(midHeight, lessThan(loadedHeight),
        reason: 'still animating toward zero, not there yet and not still '
            'at the fully-loaded height either');

    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BannerAdWidget)).height, 0,
        reason: 'settles at zero once the collapse animation finishes');
    expect(adapter.disposeCalls, 0,
        reason: 'a no-fill/error makes the banner collapse itself; that is not '
            'evidence that its still-mounted host scrolled or navigated away');
    expect(adapter.bannerListenablesByKey.values, contains(listenables),
        reason: 'the mounted error state must remain registered so the debug '
            'overlay can report it and the adapter can retry its recovery debt');
  });

  testWidgets('collapseAnimationDuration: zero disables the animation '
      '(instant jump, old behavior)', (tester) async {
    final adapter = _CollapsingBannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(
        host(const BannerAdWidget(collapseAnimationDuration: Duration.zero)));
    await tester.pump(const Duration(milliseconds: 50));

    final listenables = adapter.bannerListenablesByKey.values.single;
    listenables.isLoaded.value = true;
    listenables.visible.value = true;
    listenables.adSize.value = const Size(320, 50);
    await tester.pump();

    expect(tester.getSize(find.byType(BannerAdWidget)).height, greaterThan(0),
        reason: 'Duration.zero must still reach the final height '
            'immediately, no animation frames needed');

    // T173 must not depend on AnimatedSize: a host can explicitly request the
    // old zero-duration behavior, but its internal AdMob error collapse is
    // still not an external scroll/navigation visibility transition.
    listenables.hasError.value = true;
    listenables.isLoaded.value = false;
    await tester.pump();

    expect(tester.getSize(find.byType(BannerAdWidget)).height, 0);
    expect(adapter.disposeCalls, 0);
    expect(adapter.bannerListenablesByKey.values, contains(listenables),
        reason: 'even an instantaneous internal error collapse retains the '
            'registry key for debug reporting and recovery');
  });

  // Audit fix — consent revoke mid-session used to leave an already-loaded
  // banner mounted, visible and still auto-refreshing, since the gate was
  // only ever checked once on first mount. BannerAdWidget now subscribes to
  // AdManager().canRequestAdsListenable and reactively disposes the live
  // instance the moment the gate closes, then reloads once it reopens.
  group('T101 — consent gate closes/reopens mid-session (banner)', () {
    testWidgets(
        'consent revoked while mounted disposes the instance and collapses; '
        'reopening reloads a fresh one', (tester) async {
      final adapter = _BannerCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        AdManager().debugCanRequestAds = true;
      });

      await tester.pumpWidget(host(const BannerAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      final listenables = adapter.bannerListenablesByKey.values.single;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(320, 50);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(BannerAdWidget)).height, greaterThan(0),
          reason: 'loaded banner is visible before consent is revoked');

      AdManager().debugCanRequestAds = false;
      await tester.pumpAndSettle();

      expect(adapter.bannerListenablesByKey, isEmpty,
          reason: 'disposeBannerInstance must run as soon as the gate closes');
      expect(tester.getSize(find.byType(BannerAdWidget)).height, 0,
          reason: 'mounted banner collapses immediately on consent revoke, '
              'not just when it happens to unmount');

      // The per-widget 30s throttle is keyed by `this` and survived the
      // dispose above (it isn't part of consent state) — reset it here the
      // same way a real 30s wait would, so the reload assertion below is
      // isolated to the consent-gate behavior under test.
      AdManager().debugResetBannerCooldown();
      AdManager().debugCanRequestAds = true;
      // Not pumpAndSettle: the reloaded banner goes back through the
      // placeholder shimmer, which animates forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 2,
          reason: 'reopening the gate re-triggers a fresh load');
    });
  });

  group('round-29 audit (MAJOR): AdMob adaptive banner reload on resize', () {
    // T157 — real layout constraints, not just injected MediaQueryData:
    // BannerAdWidget now prefers its own measured width (LayoutBuilder) over
    // MediaQuery, so simulating a resize must actually change both together,
    // the same way a real rotation does.
    Widget wrapWithWidth(double width) => MediaQuery(
          data: const MediaQueryData().copyWith(size: Size(width, 800)),
          child: host(SizedBox(width: width, child: const BannerAdWidget())),
        );

    late _BannerCountingAdapter adapter;

    setUp(() {
      adapter = _BannerCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    testWidgets('a width change reloads at the new width instead of '
        'keeping the ad sized for the old one', (tester) async {
      await tester.pumpWidget(wrapWithWidth(400));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);

      await tester.pumpWidget(wrapWithWidth(800)); // e.g. rotation
      // T157 — the correction is debounced (see
      // _widthCorrectionDebounceDuration); must pump past that window.
      await tester.pump(const Duration(milliseconds: 350));

      expect(adapter.disposeCalls, 1,
          reason: 'the stale-width ad must be torn down before reloading');
      expect(adapter.loadBannerCalls, 2,
          reason: 'must request a fresh banner sized for the new width');
    });

    testWidgets(
        'an unrelated dependency change with the same width does not reload',
        (tester) async {
      await tester.pumpWidget(wrapWithWidth(400));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);

      await tester.pumpWidget(wrapWithWidth(400)); // same width, rebuild
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.disposeCalls, 0);
      expect(adapter.loadBannerCalls, 1,
          reason: 'no actual width change — must not reload');
    });
  });

  group('round-29 audit (MAJOR): AdMob banner route-away actually stops '
      'refreshing (no pause API)', () {
    late _BannerCountingAdapter adapter;
    late GlobalKey<NavigatorState> navKey;

    setUp(() {
      adapter = _CollapsingBannerCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
      navKey = GlobalKey<NavigatorState>();
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    testWidgets(
        'a route pushed on top disposes the banner instead of just hiding '
        'it, and popping back reloads it', (tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [adRouteObserver],
        home: const Scaffold(body: BannerAdWidget()),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      expect(adapter.disposeCalls, 0);

      navKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('top'))),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.disposeCalls, 1,
          reason: 'must tear the native ad object down — there is no '
              'runtime pause API on AdMob\'s Flutter plugin, so leaving it '
              'mounted-but-hidden keeps its refresh timer ticking on '
              'invisible inventory');

      navKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 2,
          reason: 'must request a fresh banner once back on top');
    });

    // Round-31 audit fix (MAJOR) — RouteAware alone never fires for an
    // IndexedStack/PageView-style tab switch (no Route change at all).
    // `Visibility(maintainState: true)` — Flutter's own widget for exactly
    // this "keep it mounted but hidden" pattern (used by real apps to
    // implement tab switching without losing tab state, the same problem
    // an IndexedStack-based bottom nav solves) — wraps its hidden child in
    // `TickerMode(enabled: false)`, which is the real, if partial, signal
    // this widget had none of before.
    testWidgets(
        'going invisible via Visibility(maintainState: true) disposes the '
        'banner the same way a route-away does, and coming back reloads it',
        (tester) async {
      final visible = ValueNotifier<bool>(true);
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, isVisible, child) => Visibility(
              visible: isVisible,
              maintainState: true,
              child: child!,
            ),
            child: const BannerAdWidget(),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      expect(adapter.disposeCalls, 0);

      visible.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.disposeCalls, 1,
          reason: 'a tab-switch hiding this widget via IndexedStack/'
              'PageView/Offstage must stop it the same way a route-away '
              'does — there is no route change here for RouteAware alone '
              'to ever see');

      visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 2,
          reason: 'must request a fresh banner once visible again');
    });

    // Round-39 audit fix — a bare IndexedStack gives neither a Route change
    // nor a TickerMode change (unlike Visibility(maintainState: true) above)
    // — AND, verified separately, the automatic VisibilityDetector cannot
    // catch it either (RenderIndexedStack.paintStack never calls paint() on
    // a non-current child, and VisibilityDetector only ever re-evaluates
    // from inside paint() — see this widget's own class doc comment). The
    // `active` param is the only thing that actually closes this gap.
    testWidgets(
        'a bare IndexedStack tab switch needs the active param — the '
        'automatic detector alone cannot see it', (tester) async {
      final selected = ValueNotifier<int>(0);
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: selected,
            builder: (context, index, _) => IndexedStack(
              index: index,
              children: [
                BannerAdWidget(active: index == 0),
                const Text('other tab'),
              ],
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      expect(adapter.disposeCalls, 0);

      selected.value = 1; // switch away — banner tab now offstage
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.disposeCalls, 1,
          reason: 'wiring active: index == 0 is what actually pauses it — '
              'IndexedStack itself gives no usable signal at all');

      selected.value = 0; // switch back
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 2,
          reason: 'must request a fresh banner once visible again');
    });

    testWidgets(
        'the manual active:false override pauses it even while the '
        'automatic detector would report it visible', (tester) async {
      final active = ValueNotifier<bool>(true);
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (context, isActive, _) =>
                BannerAdWidget(active: isActive),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      expect(adapter.disposeCalls, 0);

      active.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.disposeCalls, 1,
          reason: 'active:false must pause it regardless of what the '
              'automatic VisibilityDetector — still reporting 100% visible '
              'in this layout — would otherwise decide');

      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 2,
          reason: 'active:true must resume it');
    });

    // Round-39 audit re-review (MAJOR, independent Gemini pass) — the
    // previous test only covered active flipping AFTER the widget was
    // already mounted with the default (null). The actual primary use case
    // — an IndexedStack tab that starts at index != 0, so the widget's very
    // FIRST build already has active: false — was never covered, and was
    // in fact broken: didChangeDependencies() called _initBanner()
    // unconditionally on first mount with no active check at all.
    testWidgets(
        'mounting directly with active:false never loads, and flipping to '
        'true afterward loads it for the first time', (tester) async {
      final active = ValueNotifier<bool>(false);
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (context, isActive, _) =>
                BannerAdWidget(active: isActive),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 0,
          reason: 'a widget that starts inactive (e.g. an IndexedStack tab '
              'that isn\'t the initially-selected one) must never load an '
              'ad it was never allowed to show in the first place');

      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 1,
          reason: 'switching to the now-active tab must load it for the '
              'first time — not silently no-op because nothing was ever '
              'considered "loaded" to resume');
    });

    // The genuinely automatic case: unlike IndexedStack (which never repaints
    // an offstage child at all — see the two tests above), a scrolled-away
    // child in a plain (non-lazy) Column inside a scroll view is still
    // painted every frame, just clipped — exactly what VisibilityDetector's
    // clip-bounds check is built to catch, with zero host wiring.
    testWidgets(
        'scrolling the banner out of the viewport pauses it automatically, '
        'with no active param wired at all', (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(
          body: SingleChildScrollView(
            controller: controller,
            child: Column(
              children: const [
                SizedBox(height: 2000, child: Text('spacer')),
                BannerAdWidget(),
              ],
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      // The very first visibility callback only ever reports becoming
      // visible, never becoming invisible (nothing to compare against yet —
      // see VisibilityDetector's own _fireCallback), so mounting already
      // off-screen doesn't suppress the initial load. What matters here —
      // and what the assertions below actually cover — is that a REAL
      // scroll-away transition afterward gets caught with zero host wiring.
      expect(adapter.loadBannerCalls, 1);

      controller.jumpTo(2000); // scroll it fully into view (already loaded)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      controller.jumpTo(0); // scroll back away
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.disposeCalls, 1,
          reason: 'scrolled back out of the viewport — the automatic '
              'VisibilityDetector must catch this with zero host wiring');
    });

    group('T173 — internal error self-collapse vs real external lifecycle', () {
      testWidgets('a route push on top while errored still disposes the slot',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [adRouteObserver],
          home: const Scaffold(body: BannerAdWidget()),
        ));
        await tester.pump(const Duration(milliseconds: 50));
        expect(adapter.loadBannerCalls, 1);
        expect(adapter.disposeCalls, 0);

        final listenables = adapter.bannerListenablesByKey.values.single;
        listenables.hasError.value = true;
        listenables.isLoaded.value = false;
        await tester.pumpAndSettle();

        // Error self-collapse alone does NOT dispose.
        expect(adapter.disposeCalls, 0);
        expect(adapter.bannerListenablesByKey.values, contains(listenables));

        // But an actual route push on top MUST still dispose via didPushNext.
        navKey.currentState!.push(
          MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('top'))),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(adapter.disposeCalls, 1,
            reason: 'a real route push must still run didPushNext even if the '
                'banner was currently collapsed in error');
      });

      testWidgets('manual active: false while errored still pauses/disposes',
          (tester) async {
        final active = ValueNotifier<bool>(true);
        await tester.pumpWidget(MaterialApp(
          navigatorObservers: [adRouteObserver],
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (context, isActive, _) =>
                  BannerAdWidget(active: isActive),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 50));
        expect(adapter.loadBannerCalls, 1);
        expect(adapter.disposeCalls, 0);

        final listenables = adapter.bannerListenablesByKey.values.single;
        listenables.hasError.value = true;
        listenables.isLoaded.value = false;
        await tester.pumpAndSettle();

        expect(adapter.disposeCalls, 0);

        active.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(adapter.disposeCalls, 1,
            reason: 'explicit active:false must always take precedence');
      });

      testWidgets(
          'unmounting an errored banner still cleans up registry completely',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          navigatorObservers: [adRouteObserver],
          home: const Scaffold(body: BannerAdWidget()),
        ));
        await tester.pump(const Duration(milliseconds: 50));
        expect(adapter.bannerListenablesByKey.length, 1);

        final listenables = adapter.bannerListenablesByKey.values.single;
        listenables.hasError.value = true;
        listenables.isLoaded.value = false;
        await tester.pumpAndSettle();

        expect(adapter.bannerListenablesByKey.length, 1);

        // Replace widget tree entirely -> unmount
        await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: SizedBox()),
        ));
        await tester.pumpAndSettle();

        expect(adapter.disposeCalls, 1);
        expect(adapter.bannerListenablesByKey, isEmpty,
            reason: 'unmounting must permanently remove the slot from the registry');
      });
    });
  });

  group('T107 — placement', () {
    test('defaults to AdPlacement.unspecified', () {
      const widget = BannerAdWidget();
      expect(widget.placement, AdPlacement.unspecified);
    });

    test('accepts a custom placement', () {
      const widget = BannerAdWidget(placement: AdPlacement.shop);
      expect(widget.placement, AdPlacement.shop);
    });
  });

  // T157 — the AdMob adaptive banner used to size itself from
  // MediaQuery.of(context).size.width (the FULL SCREEN) regardless of what
  // container this widget was actually placed in — a popup, sidebar, or
  // split-screen pane narrower than the screen got a banner sized for the
  // whole screen, overflowing it.
  group('T157 — adaptive banner sizing follows its own container', () {
    late _BannerCountingAdapter adapter;

    setUp(() {
      adapter = _BannerCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    testWidgets(
        'inside SizedBox(width: 200) requests ~200 on the very first load, '
        'not the full screen width', (tester) async {
      await tester.pumpWidget(host(const SizedBox(
        width: 200,
        child: BannerAdWidget(),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      // T157 — the initial load is deferred one frame (see
      // didChangeDependencies' comment) specifically so it happens AFTER
      // build()'s own LayoutBuilder has measured the real container width —
      // one clean request at the right size, not a wasted full-screen guess
      // corrected a moment later.
      expect(adapter.loadBannerCalls, 1,
          reason: 'exactly one load — no wasted wrong-width request first');
      expect(adapter.lastWidthPx, 200,
          reason: 'T157 — must request the widget\'s own constrained width, '
              'not MediaQuery\'s full-screen width (the test viewport is '
              '800, per host()\'s default surface size)');
    });

    testWidgets(
        'unconstrained on mount (active:false, never actually loads) does '
        'not crash — sanity check that this widget tree mounts cleanly',
        (tester) async {
      await tester.pumpWidget(host(const SizedBox(
        width: 200,
        child: BannerAdWidget(active: false),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull);
      expect(adapter.loadBannerCalls, 0,
          reason: 'active:false must never load at all');
    });

    // codex re-review (P1) — mounting inactive already lays this widget out
    // once at its real, collapsed size (SizedBox.shrink() while inactive,
    // but still constrained by whatever real container the host placed it
    // in) — a later activation must use THAT measured width, not fall back
    // to MediaQuery's full-screen guess as if this were a fresh mount with
    // nothing known yet.
    testWidgets(
        'activating an inactive banner inside SizedBox(width: 200) requests '
        '~200, not the full screen width', (tester) async {
      final active = ValueNotifier<bool>(false);
      await tester.pumpWidget(host(ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (context, isActive, _) => SizedBox(
          width: 200,
          child: BannerAdWidget(active: isActive),
        ),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 0);

      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadBannerCalls, 1);
      expect(adapter.lastWidthPx, 200,
          reason: 'T157 — an IndexedStack tab activated for the first '
              'time must request its own container width, not the screen');
    });

    // codex re-review (P1) — a host resizing the container it placed this
    // widget in (e.g. a split-screen pane) rebuilds this widget with new
    // constraints without necessarily changing any MediaQuery/Route/
    // TickerMode this widget depends on — didChangeDependencies alone
    // would never fire for this; build()'s own postFrameCallback must
    // catch it independently.
    testWidgets(
        'a plain container resize (no MediaQuery/route/TickerMode change) '
        'still reloads at the new width', (tester) async {
      final width = ValueNotifier<double>(200);
      await tester.pumpWidget(host(ValueListenableBuilder<double>(
        valueListenable: width,
        // Deliberately not `const`: a `const BannerAdWidget()` is the same
        // canonicalized instance across rebuilds, so Flutter's element
        // diffing skips reconciling it entirely (`identical(new, old)`
        // short-circuits `Element.updateChild` before `update()`/`build()`
        // ever run) — this widget must still react to a resize even when a
        // host writes ordinary, non-const widget code (the common case).
        builder: (context, w, _) => SizedBox(width: w, child: BannerAdWidget()),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      expect(adapter.lastWidthPx, 200);

      width.value = 350; // e.g. a split-screen pane resizing
      await tester.pump();
      // T157 — the correction is debounced (see
      // _widthCorrectionDebounceDuration); must pump past that window.
      await tester.pump(const Duration(milliseconds: 350));

      expect(adapter.disposeCalls, 1,
          reason: 'the stale-width ad must be torn down before reloading');
      expect(adapter.loadBannerCalls, 2);
      expect(adapter.lastWidthPx, 350,
          reason: 'T157 — a bare container resize (not just rotation) '
              'must also be caught and reloaded at the new width');
    });

    // codex re-review (P1) — the strongest form of the gap: AnimatedContainer
    // relayouts its (const, identical-instance) child on every animation
    // tick without EVER rebuilding it — this widget's own Element never
    // reruns build()/didUpdateWidget at all for the whole animation, only
    // its RenderObject goes through repeated real layout passes.
    testWidgets(
        'a resize with no widget rebuild at all (AnimatedContainer '
        'animating its own width) still reloads at the final width',
        (tester) async {
      await tester.pumpWidget(host(TweenAnimationBuilder<double>(
        tween: Tween(begin: 200, end: 350),
        duration: const Duration(milliseconds: 200),
        builder: (context, w, child) => SizedBox(width: w, child: child),
        // `const` and passed as TweenAnimationBuilder's `child` — built
        // exactly ONCE for the whole animation, never rebuilt per tick.
        child: const BannerAdWidget(),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      expect(adapter.lastWidthPx, 200);

      // Advance through the animation without ever touching the widget
      // tree itself — only ticks, no new BannerAdWidget instance ever
      // created. Each tick resets the debounce (see
      // _widthCorrectionDebounceDuration), so the settle window only
      // starts counting down once the 200ms animation itself finishes.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 350));

      expect(adapter.disposeCalls, 1,
          reason: 'the stale-width ad must be torn down before reloading, '
              'even with no Element rebuild involved at all');
      expect(adapter.loadBannerCalls, 2);
      expect(adapter.lastWidthPx, 350,
          reason: 'T157 — must end up at the animation\'s FINAL width');
    });

    testWidgets(
        'rapid surface-width changes settle on one final AdMob reload',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(const SizedBox.expand(
        child: BannerAdWidget(),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);
      expect(adapter.lastWidthPx, 400);

      // Fold/unfold and split-view deliver several window metrics/layout
      // widths before settling. Every intermediate width must only reset the
      // existing debounce; none may spend another network request.
      for (final width in <double>[460, 540, 620, 700]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
      }
      expect(adapter.loadBannerCalls, 1,
          reason: 'no intermediate fold width may reload before settling');

      await tester.pump(const Duration(milliseconds: 350));
      expect(adapter.disposeCalls, 1);
      expect(adapter.loadBannerCalls, 2,
          reason: 'one reload only, after the final width settles');
      expect(adapter.lastWidthPx, 700);
    });

    testWidgets('unmounting during a pending width correction is safe',
        (tester) async {
      final width = ValueNotifier<double>(320);
      await tester.pumpWidget(host(ValueListenableBuilder<double>(
        valueListenable: width,
        builder: (context, w, _) => SizedBox(
          width: w,
          child: const BannerAdWidget(),
        ),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1);

      width.value = 700;
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await tester.pump(const Duration(milliseconds: 350));

      expect(tester.takeException(), isNull);
      expect(adapter.loadBannerCalls, 1,
          reason: 'dispose cancels the pending resize reload');
      expect(adapter.disposeCalls, 1,
          reason: 'only normal unmount cleanup disposes the instance');
      expect(adapter.bannerSlotsByKey, isEmpty);
      expect(adapter.bannerListenablesByKey, isEmpty);
      width.dispose();
    });
  });

  group('T226 — AppLovin native adaptive banner resize path', () {
    late _BannerCountingAdapter adapter;

    setUp(() {
      adapter = _BannerCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _appLovinConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    testWidgets(
        'rapid width changes keep the same preloaded AppLovin native view',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(const SizedBox.expand(
        child: BannerAdWidget(),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.preloadBannerCalls, 1);

      for (final width in <double>[460, 540, 620, 700]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
      }
      await tester.pump(const Duration(milliseconds: 350));

      expect(adapter.preloadBannerCalls, 1,
          reason: 'MaxAdView has native adaptive resizing; Dart must not '
              'tear down and preload another native view');
      expect(adapter.disposeCalls, 0);
    });
  });

  group('T229 — house ad fallback on no-fill/offline', () {
    late _BannerCountingAdapter adapter;

    setUp(() {
      // Collapsing adapter — see T173: a plain adapter makes the internal
      // zero-height error collapse look like "scrolled away" to
      // VisibilityDetector, which disposes the whole banner instance. Real
      // AdMob/AppLovin adapters implement BannerErrorSelfCollapse.
      adapter = _CollapsingBannerCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    var tapped = false;
    HouseAdItem item() {
      tapped = false;
      return HouseAdItem(
        assetPath: 'assets/house_ad.png',
        title: 'Go VIP — remove ads',
        subtitle: 'No ads, ever',
        onTap: () => tapped = true,
      );
    }

    test('houseAdDelay defaults to 10 seconds', () {
      const widget = BannerAdWidget();
      expect(widget.houseAdDelay, const Duration(seconds: 10));
      expect(widget.houseAd, isNull);
    });

    testWidgets(
        'no houseAd configured: no-fill stays blank forever — zero '
        'behavior change from T91', (tester) async {
      await tester.pumpWidget(host(const BannerAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.bannerListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump(const Duration(seconds: 15));

      expect(find.text('Go VIP — remove ads'), findsNothing);
      expect(tester.getSize(find.byType(BannerAdWidget)).height, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'houseAd configured: no-fill past the delay renders it; tap fires '
        'the callback; no AdEvent is emitted', (tester) async {
      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);
      addTearDown(sub.cancel);

      await tester.pumpWidget(host(BannerAdWidget(
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 2),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.bannerListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Go VIP — remove ads'), findsNothing,
          reason: 'must not show before the delay elapses');

      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Go VIP — remove ads'), findsOneWidget,
          reason: 'no-fill outlasted the delay — house ad must render');
      expect(tester.getSize(find.byType(BannerAdWidget)).height, greaterThan(0));

      await tester.tap(find.text('Go VIP — remove ads'));
      expect(tapped, isTrue, reason: 'tap must reach HouseAdItem.onTap');
      expect(events, isEmpty,
          reason: 'a house ad is not a real ad — no AdEvent may be emitted');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'houseAd configured but the ad recovers before the delay — house '
        'ad is never shown', (tester) async {
      await tester.pumpWidget(host(BannerAdWidget(
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 2),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.bannerListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump(const Duration(seconds: 1));

      // Real ad recovers before the 2s delay elapses.
      listenables.hasError.value = false;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(320, 50);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Go VIP — remove ads'), findsNothing,
          reason: 'the pending house-ad timer must be cancelled once the '
              'real ad fills — it must never appear');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'reconnect/fill after the house ad is shown reverts to the real ad',
        (tester) async {
      await tester.pumpWidget(host(BannerAdWidget(
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 2),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.bannerListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump(); // inserts _HouseAdSlot and starts its timer
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Go VIP — remove ads'), findsOneWidget);

      listenables.hasError.value = false;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(320, 50);
      await tester.pump();

      expect(find.text('Go VIP — remove ads'), findsNothing,
          reason: 'a real ad becoming available must replace the house ad');
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline for longer than the delay also renders the house ad',
        (tester) async {
      AdManager().debugConnectivityChanged(false);
      addTearDown(() => AdManager().debugConnectivityChanged(true));

      await tester.pumpWidget(host(BannerAdWidget(
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 2),
      )));
      await tester.pump(const Duration(seconds: 3));

      expect(find.text('Go VIP — remove ads'), findsOneWidget);
      expect(adapter.loadBannerCalls, 0,
          reason: 'still offline — no real ad load must have happened');
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposing while the house-ad timer is pending is safe — '
        'no leak or crash', (tester) async {
      await tester.pumpWidget(host(BannerAdWidget(
        houseAd: item(),
        houseAdDelay: const Duration(seconds: 5),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      final listenables = adapter.bannerListenablesByKey.values.single;
      listenables.hasError.value = true;
      listenables.isLoaded.value = false;
      await tester.pump(const Duration(seconds: 1)); // timer still pending

      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump(const Duration(seconds: 6)); // past the delay

      expect(find.byType(BannerAdWidget), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('T231 Flight Recorder visibility evidence', () {
    testWidgets(
        'visible transition records viewability and global pixel bounds when '
        'enabled', (tester) async {
      final adapter = _BannerCountingAdapter();
      final recorder = AdFlightRecorder();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
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
            child: const Column(children: [
              SizedBox(height: 100, child: Text('spacer')),
              SizedBox(
                width: 320,
                child: BannerAdWidget(collapseAnimationDuration: Duration.zero),
              ),
              SizedBox(height: 1000),
            ]),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.entries, isNotEmpty);
      final visible = recorder.entries.firstWhere(
          (entry) => entry.label == 'bannerVisible');
      expect(visible.viewabilityFraction, greaterThan(0));
      expect(visible.screenX, greaterThanOrEqualTo(0));
      expect(visible.screenY, greaterThanOrEqualTo(0));
      expect(visible.widthPx, greaterThan(0));
      // Fake adapter hasn't supplied a loaded native ad height, so height can
      // legitimately be 0 here; the coordinate path still exercised the real
      // RenderBox.localToGlobal/size read from the widget tree.
      expect(visible.heightPx, greaterThanOrEqualTo(0));

      // Move the banner fully outside the viewport — meaningful transition,
      // one new hash-chained evidence entry (not per-frame spam).
      controller.jumpTo(1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(recorder.entries.any((e) => e.label == 'bannerHidden'), isTrue);
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    testWidgets('disabled mode records nothing and leaves existing load/pause '
        'behavior unchanged', (tester) async {
      final adapter = _BannerCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();
      AdManager().disableFlightRecorder();
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
            child: const Column(children: [
              SizedBox(height: 2000, child: Text('spacer')),
              BannerAdWidget(),
            ]),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadBannerCalls, 1,
          reason: 'default-off recorder must not change banner loading');

      controller.jumpTo(2000); // scroll it fully into view
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      controller.jumpTo(0); // scroll back away
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.disposeCalls, 1,
          reason: 'existing visibility pause behavior remains intact');
      expect(AdManager().flightRecorder, isNull,
          reason: 'no recorder was created implicitly');
      expect(tester.takeException(), isNull);
    });

    testWidgets('disposing before a queued visibility callback cannot write '
        'a late entry or throw', (tester) async {
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);
      addTearDown(AdManager().disableFlightRecorder);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: BannerAdWidget()),
      ));
      // Unmount immediately without pumping the visibility callback first.
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ));
      final countAfterDispose = recorder.entries.length;
      await tester.pump(const Duration(milliseconds: 100));

      expect(recorder.entries, hasLength(countAfterDispose),
          reason: 'the mounted guard rejects any post-dispose callback');
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
