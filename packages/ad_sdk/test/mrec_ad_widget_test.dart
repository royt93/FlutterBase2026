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
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  final AdSlot mrecSlot = AdSlot(type: AdSlotType.mrec);

  int loadMrecCalls = 0;

  @override
  final BannerListenables mrec = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );

  @override
  String get tag => 'counting';
  @override
  Future<void> loadMrecIfNeeded(double widthPx) async => loadMrecCalls++;
  @override
  Future<void> preloadMrec() async {}
  // No-ops so _retryRefillAds (fired on reconnect) doesn't hit noSuchMethod.
  @override
  Future<void> preloadBanner() async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Widget? buildAdmobMrecView() => null; // placeholder path, no native view
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

  testWidgets('mounts and disposes without throwing', (tester) async {
    await tester.pumpWidget(host(const MrecAdWidget()));
    await tester.pumpAndSettle();

    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();

    expect(find.byType(MrecAdWidget), findsNothing);
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
