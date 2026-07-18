// Widget tests for NativeAdWidget — mirrors mrec_ad_widget_test.dart's
// gating coverage, minus route-pause/auto-refresh (not applicable to native:
// no adaptive width, and AppLovin's MaxNativeAdView is self-contained).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativeCountingAdapter implements AdProviderAdapter {
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
  @override
  final AdSlot nativeSlot = AdSlot(type: AdSlotType.native);

  int loadNativeCalls = 0;

  @override
  final BannerListenables mrec = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );
  @override
  final BannerListenables native = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );

  @override
  String get tag => 'counting';
  @override
  Future<void> preloadNative() async => loadNativeCalls++;
  @override
  Widget? buildAdmobNativeView() => null; // placeholder path, no native view
  @override
  String? get appLovinNativeId => 'native-id';
  @override
  Future<void> loadMrecIfNeeded(double widthPx) async {}
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
  Widget? buildAdmobMrecView() => null;
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
    nativeId: 'ca-app-pub-3940256099942544/2247696110',
  ),
);

const _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'key',
    bannerId: 'banner-id',
    interstitialId: 'inter-id',
    appOpenId: 'appopen-id',
    rewardedId: 'rewarded-id',
    nativeId: 'native-id',
  ),
);

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('renders an empty box when the SDK is not initialised',
      (tester) async {
    await tester.pumpWidget(host(const NativeAdWidget()));
    await tester.pumpAndSettle();

    expect(find.byType(NativeAdWidget), findsOneWidget);
    final size = tester.getSize(find.byType(NativeAdWidget));
    expect(size.height, 0,
        reason: 'uninitialised native ad must collapse to zero height');
  });

  testWidgets('mounts and disposes without throwing', (tester) async {
    await tester.pumpWidget(host(const NativeAdWidget()));
    await tester.pumpAndSettle();

    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();

    expect(find.byType(NativeAdWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated rebuilds trigger exactly one AdMob native load',
      (tester) async {
    final adapter = _NativeCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetNativeCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const NativeAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 0; i < 5; i++) {
      AdManager().initRevision.value = AdManager().initRevision.value + 1;
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadNativeCalls, 1,
        reason: 'native ad loads once despite repeated rebuilds');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AppLovin provider never calls preloadNative (loads on mount)',
      (tester) async {
    final adapter = _NativeCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _appLovinConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetNativeCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const NativeAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadNativeCalls, 0,
        reason: 'AppLovin MaxNativeAdView loads itself on mount');
    expect(tester.takeException(), isNull);
  });

  testWidgets('native ad collapses offline and reloads on reconnect',
      (tester) async {
    final adapter = _NativeCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetNativeCooldown();
    AdManager().debugReconnectDebounce = Duration.zero;
    AdManager().debugConnectivityChanged(false); // go offline
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugConnectivityChanged(true);
    });

    await tester.pumpWidget(host(const NativeAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadNativeCalls, 0, reason: 'offline → no native load');

    AdManager().debugConnectivityChanged(true);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    await tester.pump();
    expect(adapter.loadNativeCalls, 1, reason: 'reconnect → native reloads');
    expect(tester.takeException(), isNull);
  });

  testWidgets('VIP active → native ad collapses to empty box, never loads',
      (tester) async {
    final adapter = _NativeCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetNativeCooldown();
    AdManager().debugVipManager = _FakeVip(true);
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
    });

    await tester.pumpWidget(host(const NativeAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.loadNativeCalls, 0, reason: 'VIP member → no native load');
    final size = tester.getSize(find.byType(NativeAdWidget));
    expect(size.height, 0,
        reason: 'VIP member must collapse to zero height, like uninitialised');
    expect(tester.takeException(), isNull);
  });

  group('Compliance — "Ad" badge', () {
    testWidgets(
        'AppLovin custom layout shows an "Ad" badge once loaded (compliance)',
        (tester) async {
      final adapter = _NativeCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _appLovinConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(host(const NativeAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));

      // Not yet loaded: shimmer placeholder, no "Ad" text yet.
      expect(find.text('Ad'), findsNothing);

      // Simulate MaxNativeAdView's onAdLoadedCallback firing.
      adapter.native.isLoaded.value = true;
      await tester.pump();

      expect(find.text('Ad'), findsOneWidget,
          reason:
              'AppLovin custom native layout must self-draw an "Ad" compliance badge once loaded');
    });

    testWidgets(
        'AdMob native branch does not add its own badge (template '
        'auto-draws it, avoiding a double label)', (tester) async {
      final adapter = _NativeCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(host(const NativeAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));

      adapter.native.isLoaded.value = true;
      await tester.pump();

      expect(find.text('Ad'), findsNothing,
          reason:
              'AdMob native template already draws its own "Ad"/AdChoices label');
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
