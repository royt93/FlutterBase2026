// Regression test for a memory-leak audit finding on BannerAdWidget.
//
// Originally verified MANUALLY: 25 mount/unmount cycles of the banner widget,
// eyeballed for growth in RouteAware subscriptions / banner-load stacking.
// This automates that check so it runs on every CI build instead of during
// an occasional manual audit.
//
// What a leak would look like here:
//   - BannerAdWidget.dispose() unsubscribes from `adRouteObserver` and
//     disposes its 3 own ValueNotifiers (_initStarted, _allowed, _admobIsTop).
//     If unsubscribe were ever skipped, `adRouteObserver` would keep a
//     reference to a disposed State forever (classic RouteObserver leak) and
//     — since didPush/didPushNext/didPopNext don't `mounted`-guard — a later
//     navigation would call back into the disposed widget and throw.
//   - `AdManager.recordBannerLoad()` is cooldown-gated; a leaking widget that
//     re-triggers `_initBanner` on every rebuild would make the load count
//     grow unboundedly with the number of mount cycles instead of staying
//     flat.
//
// Harness borrowed from banner_ad_widget_test.dart (same `_CountingAdapter`
// fake, same `host()` wrapper) rather than inventing a new one.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// AdMob-provider fake that counts banner loads — same shape as the one in
/// banner_ad_widget_test.dart (kept local; both files are small enough that a
/// shared test-utils file would be more ceremony than it's worth).
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
  // T65 (phase 2) — keyed by widget instance, mirroring the real adapters.
  // This file's whole purpose is leak auditing, so exposing these maps lets
  // the test assert they don't grow unboundedly across mount/unmount cycles
  // the way the ORIGINAL leak this file guards against would have.
  final Map<Object, AdSlot> bannerSlotsByKey = {};
  final Map<Object, BannerListenables> bannerListenablesByKey = {};
  int loadBannerCalls = 0;

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
    bannerSlotsByKey.remove(key);
    bannerListenablesByKey.remove(key);
  }

  @override
  String get tag => 'counting-leak';
  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async =>
      loadBannerCalls++;
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Widget? buildAdmobBannerView(Object key) =>
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
  ),
);

void main() {
  const cycles = 25; // mirrors the original manual audit's cycle count.

  testWidgets(
      '25 mount/unmount cycles leave no dangling RouteAware subscription '
      'and do not stack banner loads', (tester) async {
    final adapter = _CountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    // Single stable host + route across all cycles: only the BannerAdWidget
    // child is swapped in/out, so `adRouteObserver` sees the same
    // ModalRoute subscribed/unsubscribed 25 times over rather than 25
    // different routes (which would trivially never "leak" onto each other).
    late BuildContext hostContext;
    Widget host(Widget child) => MaterialApp(
          navigatorObservers: [adRouteObserver],
          home: Scaffold(
            body: Builder(builder: (context) {
              hostContext = context;
              return Center(child: child);
            }),
          ),
        );

    for (var i = 0; i < cycles; i++) {
      await tester.pumpWidget(host(const BannerAdWidget()));
      await tester.pump(const Duration(milliseconds: 20));

      final route = ModalRoute.of(hostContext);
      expect(route, isNotNull);
      expect(adRouteObserver.debugObservingRoute(route!), isTrue,
          reason: 'cycle $i: mounted banner must subscribe to its route');

      // Unmount: swap the banner out for an empty placeholder.
      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump(const Duration(milliseconds: 20));

      expect(adRouteObserver.debugObservingRoute(route), isFalse,
          reason: 'cycle $i: dispose() must unsubscribe — a leak would leave '
              'this route (or a growing set of prior routes) still observed');
      expect(tester.takeException(), isNull,
          reason: 'cycle $i: no leaked/stale RouteAware callback may fire');
    }

    // T65 (phase 2) — this used to assert `<= 2` loads, relying on a single
    // GLOBAL cooldown timer to coincidentally suppress reloads across
    // separate mount cycles. That timer is now keyed per widget instance
    // (deliberately — a feed of simultaneous banners must not have one
    // instance's cooldown block another's first-ever load), so each of
    // these 25 FRESH widget instances legitimately gets its own fresh
    // cooldown state and loads exactly once. The real leak this file
    // guards against — unbounded growth across cycles — is verified below
    // by asserting the keyed maps return to empty, not by an artificially
    // low call count.
    expect(adapter.loadBannerCalls, cycles,
        reason: 'each of the $cycles distinct widget instances loads '
            'exactly once (no leaked cross-instance cooldown/cache)');

    // T65 (phase 2) — the keyed refactor's own new leak risk: each mount
    // creates a fresh widget State (a fresh map key). If dispose() didn't
    // call disposeBannerInstance, this map would grow by one entry per
    // cycle instead of returning to empty.
    expect(adapter.bannerSlotsByKey, isEmpty,
        reason: '$cycles mount/unmount cycles must not leak keyed AdSlots');
    expect(adapter.bannerListenablesByKey, isEmpty,
        reason:
            '$cycles mount/unmount cycles must not leak keyed BannerListenables');
  });
}
