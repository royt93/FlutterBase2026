// Widget tests for NativeAdWidget — mirrors mrec_ad_widget_test.dart's
// gating coverage, minus route-pause/auto-refresh (not applicable to native:
// no adaptive width, and AppLovin's MaxNativeAdView is self-contained).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_max/applovin_max.dart';
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
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;
  final AdSlot _mrecSlot = AdSlot(type: AdSlotType.mrec);
  @override
  AdSlot mrecSlot(Object key) => _mrecSlot;

  // T65 (phase 1) — keyed by widget instance, mirroring the real adapters.
  final Map<Object, AdSlot> nativeSlotsByKey = {};
  final Map<Object, BannerListenables> nativeListenablesByKey = {};
  int loadNativeCalls = 0;

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
  BannerListenables native(Object key) {
    return nativeListenablesByKey.putIfAbsent(
        key,
        () => BannerListenables(
              isLoaded: ValueNotifier<bool>(false),
              hasError: ValueNotifier<bool>(false),
              adSize: ValueNotifier<Size?>(null),
              autoRefreshEnabled: ValueNotifier<bool>(true),
              visible: ValueNotifier<bool>(true),
            ));
  }

  @override
  void disposeNativeInstance(Object key) {
    nativeSlotsByKey.remove(key);
    nativeListenablesByKey.remove(key);
  }

  @override
  String get tag => 'counting';
  TemplateType? lastRequestedTemplateType;
  @override
  Future<void> preloadNative(Object key,
      {TemplateType templateType = TemplateType.medium}) async {
    lastRequestedTemplateType = templateType;
    loadNativeCalls++;
  }
  @override
  Widget? buildAdmobNativeView(Object key) =>
      null; // placeholder path, no native view
  @override
  String? get appLovinNativeId => 'native-id';
  @override
  BannerListenables mrec(Object key) => _mrec;
  @override
  Future<void> loadMrecIfNeeded(Object key, double widthPx) async {}
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

  // T65 — before the keyed refactor, two simultaneous NativeAdWidgets on
  // AdMob shared one adapter-level NativeAd/AdSlot/BannerListenables bundle:
  // google_mobile_ads would throw "This AdWidget is already in the Widget
  // tree" once both mounted the same underlying ad. This fake adapter
  // doesn't reproduce that exact platform-channel crash, but it does prove
  // the widget layer now generates independent keys and independent state.
  testWidgets(
      'two simultaneous NativeAdWidgets on AdMob get independent slots, '
      'no crash', (tester) async {
    final adapter = _NativeCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetNativeCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    await tester.pumpWidget(host(const SingleChildScrollView(
      child: Column(
        children: [NativeAdWidget(), NativeAdWidget()],
      ),
    )));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(NativeAdWidget), findsNWidgets(2));
    expect(adapter.nativeListenablesByKey.length, 2,
        reason:
            'each widget instance must get its own BannerListenables, not share one');
    expect(adapter.loadNativeCalls, 2,
        reason: 'each widget triggers its own load');
    expect(tester.takeException(), isNull);

    // One instance finishing loading must not affect the other.
    adapter.nativeListenablesByKey.values.first.isLoaded.value = true;
    await tester.pump();
    final loadedStates =
        adapter.nativeListenablesByKey.values.map((l) => l.isLoaded.value);
    expect(loadedStates, containsAllInOrder([true, false]),
        reason: 'flipping one instance loaded must not flip the other');
    expect(tester.takeException(), isNull);
  });

  // T73 — templateType/height configuration.
  group('templateType / height (T73)', () {
    setUp(() {
      AdManager().debugSetAdapter(_NativeCountingAdapter());
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    testWidgets('default (no params) keeps the original 320 height',
        (tester) async {
      await tester.pumpWidget(host(const NativeAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.getSize(find.byType(NativeAdWidget)).height, 320);
    });

    testWidgets('templateType: small renders at the compact 90 height',
        (tester) async {
      await tester.pumpWidget(
          host(const NativeAdWidget(templateType: TemplateType.small)));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.getSize(find.byType(NativeAdWidget)).height, 90);
    });

    testWidgets('explicit height overrides the templateType default',
        (tester) async {
      await tester.pumpWidget(host(const NativeAdWidget(
          templateType: TemplateType.small, height: 120)));
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.getSize(find.byType(NativeAdWidget)).height, 120,
          reason: 'an explicit height must win over the templateType default');
    });

    testWidgets('AdMob: templateType is threaded through to the adapter',
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

      await tester.pumpWidget(
          host(const NativeAdWidget(templateType: TemplateType.small)));
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.lastRequestedTemplateType, TemplateType.small);
    });
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

  // T62 — MaxNativeAdView "loads on mount" (its own dartdoc, and the
  // comment above) only works if it actually GETS mounted. _NativeContainer
  // gated `child()` behind `isLoaded`, but `isLoaded` is only ever flipped
  // true BY MaxNativeAdView's own onAdLoadedCallback — a callback that can
  // never fire if the widget carrying it is never built. AppLovin's
  // preloadNative() is a documented no-op, so nothing else can break this
  // cycle: native ads would never load on AppLovin, ever, in production.
  testWidgets(
      'AppLovin native view actually mounts on its own so it CAN load '
      '(not stuck behind its own isLoaded gate)', (tester) async {
    final adapter = _NativeCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _appLovinConfig;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetNativeCooldown();
    addTearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    // Deliberately NOT touching adapter.native.isLoaded — that's the whole
    // point: in real production nothing else ever sets it, so MaxNativeAdView
    // must mount on its own merit, before any load ever completes.
    await tester.pumpWidget(host(const NativeAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MaxNativeAdView), findsOneWidget,
        reason: 'MaxNativeAdView must mount on its own so its own '
            'onAdLoadedCallback can ever fire — gating it behind isLoaded '
            'is a deadlock: nothing else can ever set isLoaded true');
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

  testWidgets(
      'round-29 audit (MINOR): a load failure retries after backoff '
      'instead of staying blank for the widget\'s lifetime', (tester) async {
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
    expect(adapter.loadNativeCalls, 1);

    // The native ad fails to load.
    adapter.nativeListenablesByKey.values.first.hasError.value = true;
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadNativeCalls, 1, reason: 'no retry yet — too soon');

    // `tester.pump(duration)` fast-forwards the fake Timer clock but not
    // real wall-clock `DateTime.now()`, which the adapter-level load
    // cooldown (separate from this retry timer) reads — reset it to
    // simulate the real time that would have also elapsed by the time a
    // 30s retry timer fires for real.
    AdManager().debugResetNativeCooldown();
    await tester.pump(const Duration(seconds: 31));
    expect(adapter.loadNativeCalls, 2,
        reason: 'must retry after backoff instead of staying blank until '
            'the widget is disposed and recreated');
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
      adapter.nativeListenablesByKey.values.single.isLoaded.value = true;
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

      adapter.nativeListenablesByKey.values.single.isLoaded.value = true;
      await tester.pump();

      expect(find.text('Ad'), findsNothing,
          reason:
              'AdMob native template already draws its own "Ad"/AdChoices label');
    });
  });

  group('T100 — gate re-check when state changes mid-flight', () {
    testWidgets(
        'consent revoked after the gate passes disposes the mounted instance '
        'immediately, before any in-flight load can land and render',
        (tester) async {
      final adapter = _NativeCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        AdManager().debugCanRequestAds = true;
      });

      await tester.pumpWidget(host(const NativeAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 1,
          reason: 'gate passed while consent was still granted');
      // AppLovin native has no adapter-level "slot" — the widget only ever
      // reads/writes listenables via adapter.native(key). nativeSlotsByKey
      // stays empty on this path; nativeListenablesByKey is the map that
      // actually tracks the mounted instance.
      expect(adapter.nativeListenablesByKey, isNotEmpty);

      // Consent revoked NOW — strictly after the load request already went
      // out. A real ad network's own SDK already dispatched this request
      // with whatever consent state applied at THAT moment; revoking
      // consent afterwards cannot un-send it. Audit fix: the widget no
      // longer waits for that in-flight load to land and render anyway — it
      // reactively disposes its mounted instance the moment the gate closes.
      AdManager().debugCanRequestAds = false;
      await tester.pump();

      expect(adapter.nativeListenablesByKey, isEmpty,
          reason: 'disposeNativeInstance must run as soon as the gate closes');
      expect(tester.getSize(find.byType(NativeAdWidget)).height, 0,
          reason: 'widget collapses immediately, not just once a still-'
              'in-flight load happens to land');
    });

    testWidgets(
        'a later consent revoke does not stop a SUBSEQUENT rebuild from '
        'requesting a fresh load either — the gate is re-evaluated fresh '
        'on the retry path, it is just never revoked once already granted',
        (tester) async {
      final adapter = _NativeCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = false; // starts WITHOUT consent
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        AdManager().debugCanRequestAds = true;
      });

      await tester.pumpWidget(host(const NativeAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 0,
          reason: 'no consent yet — must not load');
      expect(tester.getSize(find.byType(NativeAdWidget)).height, 0);

      // Consent granted later; a rebuild (route change, parent setState,
      // ...) is what actually re-runs the gate — confirms the retry path
      // in build() does re-check every condition fresh, not just cache the
      // first failure forever.
      AdManager().debugCanRequestAds = true;
      await tester.pumpWidget(host(const NativeAdWidget(key: Key('rebuilt'))));
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadNativeCalls, 1,
          reason: 'the gate must be re-evaluated once consent is granted');
    });

    testWidgets(
        'consent revoked while mounted disposes the instance and collapses; '
        'reopening reloads a fresh one', (tester) async {
      final adapter = _NativeCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        AdManager().debugCanRequestAds = true;
      });

      await tester.pumpWidget(host(const NativeAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 1);
      final listenables = adapter.nativeListenablesByKey.values.single;
      listenables.isLoaded.value = true;
      listenables.visible.value = true;
      listenables.adSize.value = const Size(300, 250);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(NativeAdWidget)).height, greaterThan(0),
          reason: 'loaded native ad is visible before consent is revoked');

      AdManager().debugCanRequestAds = false;
      await tester.pumpAndSettle();

      expect(adapter.nativeListenablesByKey, isEmpty,
          reason: 'disposeNativeInstance must run as soon as the gate closes');
      expect(tester.getSize(find.byType(NativeAdWidget)).height, 0,
          reason: 'mounted native ad collapses immediately on consent '
              'revoke, not just when it happens to unmount');

      // The per-widget 30s throttle is keyed by `this` and survived the
      // dispose above (it isn't part of consent state) — reset it here the
      // same way a real 30s wait would, so the reload assertion below is
      // isolated to the consent-gate behavior under test.
      AdManager().debugResetNativeCooldown();
      AdManager().debugCanRequestAds = true;
      // Not pumpAndSettle: the reloaded native ad goes back through the
      // placeholder shimmer, which animates forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadNativeCalls, 2,
          reason: 'reopening the gate re-triggers a fresh load');
    });
  });

  group('T107 — placement', () {
    test('defaults to AdPlacement.unspecified', () {
      const widget = NativeAdWidget();
      expect(widget.placement, AdPlacement.unspecified);
    });

    test('accepts a custom placement', () {
      const widget = NativeAdWidget(placement: AdPlacement.shop);
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
