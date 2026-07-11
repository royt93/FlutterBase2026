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

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
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
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int loadBannerCalls = 0;

  @override
  final BannerListenables banner = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );

  @override
  String get tag => 'counting';
  @override
  Future<void> loadBannerIfNeeded(double widthPx) async => loadBannerCalls++;
  @override
  Future<void> preloadBanner() async {}
  // No-ops so _retryRefillAds (fired on reconnect) doesn't hit noSuchMethod.
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Widget? buildAdmobBannerView() => null; // placeholder path, no native view
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
    // unbounded with iteration count.
    expect(adapter.loadBannerCalls, lessThanOrEqualTo(4),
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
