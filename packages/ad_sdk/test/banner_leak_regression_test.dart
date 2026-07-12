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
  String get tag => 'counting-leak';
  @override
  Future<void> loadBannerIfNeeded(double widthPx) async => loadBannerCalls++;
  @override
  Future<void> preloadBanner() async {}
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

    // Cooldown-gated: repeated mounts of the same route must not stack
    // duplicate banner loads. A leak that re-fires `_initBanner` on every
    // remount would make this grow with `cycles` instead of staying tiny.
    expect(adapter.loadBannerCalls, lessThanOrEqualTo(2),
        reason: '$cycles mount/unmount cycles must not stack banner loads');
  });
}
