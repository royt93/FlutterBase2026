// Widget tests for NativeAdWidget — mirrors mrec_ad_widget_test.dart's
// gating coverage, minus route-pause/auto-refresh (not applicable to native:
// no adaptive width, and AppLovin's MaxNativeAdView is self-contained).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'applovin_adapter_test.dart' show FakeAppLovinBridge;

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
  // Round 44 — settable so tests can tell "hidden" apart from "no view yet".
  Widget? nativeViewToReturn;
  @override
  Widget? buildAdmobNativeView(Object key) => nativeViewToReturn;
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

  // Audit round 42, BLOCKER (codex, independently verified) — AppLovin's
  // native-ad integration guide requires MaxNativeAdOptionsView (the
  // privacy-information/AdChoices-equivalent icon) somewhere in the custom
  // layout the package owns. Without it, every AppLovin native ad impression
  // is policy-non-compliant, unconditionally, on both platforms.
  testWidgets('AppLovin native ad layout includes the mandatory privacy '
      'information view (MaxNativeAdOptionsView)', (tester) async {
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

    expect(find.byType(MaxNativeAdOptionsView), findsOneWidget,
        reason: 'AppLovin policy requires the privacy-information view to '
            'be present in every native ad layout the package renders');
  });

  // Round-44 audit fix — a live native ad used to stay mounted and visible
  // underneath an App Open ad (its own adapter doc comment admitted native
  // was "never hidden the way banner/mrec are hidden"). `AdManager
  // .nativeVisible(key)` now drives the widget the same way `bannerVisible`
  // already does for BannerAdWidget.
  group('Round 44 — App Open hides native ad', () {
    testWidgets('AppLovin native view collapses while nativeVisible is false',
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

      expect(find.byType(MaxNativeAdView), findsOneWidget,
          reason: 'sanity — mounted normally with no fullscreen ad up');

      final l = adapter.nativeListenablesByKey.values.first;
      l.visible.value = false; // what setInlineAdsHidden(true) now does
      await tester.pump();

      expect(find.byType(MaxNativeAdView), findsNothing,
          reason: 'THE finding — a native ad drawn on top of an App Open ad '
              'is the placement round 23 already fixed for banner/MREC');

      l.visible.value = true; // App Open dismissed
      await tester.pump();

      expect(find.byType(MaxNativeAdView), findsOneWidget,
          reason: 'and it must come back once the fullscreen ad is gone');
    });

    testWidgets('AdMob native view collapses while nativeVisible is false',
        (tester) async {
      final adapter = _NativeCountingAdapter()
        ..nativeViewToReturn = Container(key: const Key('admob-native-view'));
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
      adapter.nativeListenablesByKey.values.first.isLoaded.value = true;
      await tester.pump();

      expect(find.byKey(const Key('admob-native-view')), findsOneWidget,
          reason: 'sanity — mounted normally with no fullscreen ad up');

      final l = adapter.nativeListenablesByKey.values.first;
      l.visible.value = false;
      await tester.pump();

      expect(find.byKey(const Key('admob-native-view')), findsNothing,
          reason: 'THE finding — same placement violation as the AppLovin '
              'branch, for the AdMob provider');

      l.visible.value = true;
      await tester.pump();

      expect(find.byKey(const Key('admob-native-view')), findsOneWidget);
    });
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

  testWidgets(
      'round-31 audit (MAJOR): the retry-after-backoff mechanism survives '
      'a consent-gate dispose/revive cycle, not just the widget\'s own '
      'initState lifetime', (tester) async {
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

    // Revive cycle: gate closes (disposeNativeInstance drops the bundle —
    // and with it the OLD `nativeHasError` notifier), then reopens (a
    // BRAND NEW bundle/notifier is created on the next access).
    AdManager().debugCanRequestAds = false;
    await tester.pumpAndSettle();
    expect(adapter.nativeListenablesByKey, isEmpty);
    AdManager().debugResetNativeCooldown();
    AdManager().debugCanRequestAds = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadNativeCalls, 2, reason: 'sanity: revive reloaded');

    // Fail on the NEW (post-revive) notifier.
    adapter.nativeListenablesByKey.values.single.hasError.value = true;
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadNativeCalls, 2, reason: 'no retry yet — too soon');

    AdManager().debugResetNativeCooldown();
    await tester.pump(const Duration(seconds: 31));

    expect(adapter.loadNativeCalls, 3,
        reason: 'the retry listener must be subscribed to the POST-REVIVE '
            'notifier — if it is still attached to the notifier from '
            'before the revive, this failure is never observed and no '
            'retry ever fires');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'round-38 audit (MAJOR): AppLovin native ad error-retry disposes the '
      'stale bundle so the widget can actually recover, not just re-trigger '
      'a load that a still-true hasError notifier keeps hidden forever',
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
    expect(adapter.nativeListenablesByKey, isNotEmpty);
    final firstBundle = adapter.nativeListenablesByKey.values.first;

    // The native ad fails to load once (transient no-fill/network blip).
    firstBundle.hasError.value = true;
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getSize(find.byType(NativeAdWidget)).height, 0,
        reason: 'collapses while hasError is true, same as before the fix');

    AdManager().debugResetNativeCooldown();
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    await tester.pump();

    expect(adapter.nativeListenablesByKey, isNotEmpty);
    final rebuiltBundle = adapter.nativeListenablesByKey.values.first;
    expect(identical(rebuiltBundle, firstBundle), isFalse,
        reason: 'the retry must dispose the stale, permanently-errored '
            'bundle and let mount recreate a fresh one — before the fix, '
            'nothing ever disposed it, so the same stuck-true hasError '
            'notifier lived on forever and the widget stayed blank');
    expect(rebuiltBundle.hasError.value, isFalse);
    expect(tester.getSize(find.byType(NativeAdWidget)).height, greaterThan(0),
        reason: 'AppLovin native ad recovers and renders again after retry');
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

  group('R45-02 — AppLovin native click after widget disposal (audit round '
      '45)', () {
    // codex exec (round-45 independent audit) found this: unlike
    // onAdRevenuePaidCallback (round-33 fix, R33-03), onAdClickedCallback
    // had no `isNativeInstanceDisposed` check, so a click callback that
    // arrives after the user has already navigated away (widget disposed,
    // instanceKey tombstoned) was still recorded against the shared
    // click/invalid-traffic counters and emitted through eventSink — and,
    // if the adapter had since been reinitialised, could be misattributed
    // to a brand-new session. Needs a *real* AppLovinAdapter, not the
    // lightweight `_NativeCountingAdapter` fake used elsewhere in this
    // file, because the guard is specifically `adapter is AppLovinAdapter
    // && adapter.isNativeInstanceDisposed(instanceKey)`.
    testWidgets(
        'a click callback delivered after the widget (and its native '
        'instance) is disposed is neither recorded nor emitted',
        (tester) async {
      final bridge = FakeAppLovinBridge();
      final adapter = AppLovinAdapter(bridge: bridge);
      expect(
        await adapter.initialize(_appLovinConfig,
            consent: const AdConsent(hasUserConsent: true)),
        isTrue,
      );
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _appLovinConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        adapter.dispose();
      });

      await tester.pumpWidget(host(const NativeAdWidget()));
      await tester.pump(const Duration(milliseconds: 50));

      final listener = tester
          .widget<MaxNativeAdView>(find.byType(MaxNativeAdView))
          .listener;
      expect(listener, isNotNull);

      // Unmount — same as navigating away from the screen. This tombstones
      // the widget's instanceKey on the real adapter.
      await tester.pumpWidget(host(const SizedBox()));
      await tester.pump();
      expect(find.byType(NativeAdWidget), findsNothing);

      final events = <Object>[];
      adapter.eventSink = events.add;

      // The platform side queued this click before dispose and delivers it
      // late — the exact race R45-02 fixed.
      listener!.onAdClickedCallback(MaxAd(
          'native-id',
          'NATIVE',
          null,
          'net',
          '',
          0.0,
          'exact',
          'cid',
          'dsp',
          '',
          0,
          MaxAdWaterfallInfo('', '', const [], 0),
          null,
          null));

      expect(events, isEmpty,
          reason: 'a click for an already-disposed native instance must '
              'not be recorded or emitted — the instance no longer exists '
              'and, if the adapter has since been reinitialised, must not '
              'be misattributed to a new session');
      expect(tester.takeException(), isNull);
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

  group('T154 — active (IndexedStack visibility)', () {
    // The actual bug: a native ad mounted on a hidden IndexedStack tab
    // loaded (and counted an impression for) content nobody ever saw.
    // Mirrors MrecAdWidget's identical test for the identical gap.
    testWidgets(
        'mounting directly with active:false never loads, flipping to true '
        'afterward loads it for the first time', (tester) async {
      final adapter = _NativeCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      final active = ValueNotifier<bool>(false);
      await tester.pumpWidget(host(ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (context, isActive, _) => NativeAdWidget(active: isActive),
      )));
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadNativeCalls, 0,
          reason: 'a widget that starts inactive must never load an ad it '
              'was never allowed to show in the first place — the T154 '
              'bug this test pins');

      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadNativeCalls, 1,
          reason: 'switching to active must load it for the first time');
    });

    // Codex re-review (P2) of the first version of this fix: the retry-
    // after-failure timer used to early-return while inactive, skipping the
    // dispose+reset it must always do — leaving the bundle stuck
    // `_allowed == true` + errored forever, so reactivating the widget
    // later never loaded anything again (didUpdateWidget's own retry only
    // fires on `!_allowed.value`).
    testWidgets(
        'a load failure while hidden still resets so reactivating later '
        'retries, instead of staying blank forever', (tester) async {
      final adapter = _NativeCountingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig;
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetNativeCooldown();
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      final active = ValueNotifier<bool>(true);
      await tester.pumpWidget(host(ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (context, isActive, _) => NativeAdWidget(active: isActive),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 1);

      // The load fails, then the tab is hidden before the 30s retry timer
      // fires.
      adapter.nativeListenablesByKey.values.first.hasError.value = true;
      active.value = false;
      await tester.pump(const Duration(milliseconds: 50));

      AdManager().debugResetNativeCooldown();
      await tester.pump(const Duration(seconds: 31));
      expect(adapter.loadNativeCalls, 1,
          reason: 'still hidden — must not reload while nobody can see it');

      // Tab becomes visible again — the bundle must have been reset by the
      // timer above (even though it skipped the reload itself), or this
      // never recovers.
      active.value = true;
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 2,
          reason: 'T154 (codex re-review) — reactivating must retry, not '
              'stay stuck errored forever because the retry timer fired '
              'while hidden');
      expect(tester.takeException(), isNull);
    });

    // Codex re-review (P1) of the second version of this fix: consent-reopen/
    // personalisation-withdrawn/build's own retry all defer the actual
    // _initNative() call through addPostFrameCallback, checking `active` only
    // at SCHEDULE time — a parent rebuild can flip it to hidden before the
    // callback actually FIRES, one or more frames later.
    testWidgets(
        'a deferred reload scheduled while active must not fire once the '
        'tab has since become hidden', (tester) async {
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

      final active = ValueNotifier<bool>(true);
      await tester.pumpWidget(host(ValueListenableBuilder<bool>(
        valueListenable: active,
        builder: (context, isActive, _) => NativeAdWidget(active: isActive),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 1);

      // Close the gate (disposes the instance, _allowed → false), then
      // reopen it — _onCanRequestAdsChanged sees widget.active == true right
      // now and schedules a post-frame reload.
      AdManager().debugCanRequestAds = false;
      await tester.pump(const Duration(milliseconds: 50));
      AdManager().debugCanRequestAds = true;

      // The tab is hidden before that scheduled callback actually runs.
      active.value = false;
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadNativeCalls, 1,
          reason: 'T154 (codex re-review, P1) — the deferred reload must '
              'recheck active at fire time, not just when it was scheduled, '
              'or a hidden tab still loads (and counts an impression for) '
              'an ad nobody sees');
      expect(tester.takeException(), isNull);
    });

    // Codex re-review (P1) of the third version of this fix: a queued
    // post-frame reload (scheduled while `_allowed` was false) can be
    // overtaken by `didUpdateWidget` firing a SYNCHRONOUS `_initNative()`
    // earlier in the same frame — ANY parent rebuild re-triggers
    // didUpdateWidget, not just an active flip. Without a guard, both calls
    // pass every gate and the real provider load fires twice for one
    // transition (double impression/request — an ad-network policy risk).
    testWidgets(
        'a post-frame reload racing a synchronous didUpdateWidget reload '
        'must only load once', (tester) async {
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

      final rebuildTick = ValueNotifier<int>(0);
      await tester.pumpWidget(host(ValueListenableBuilder<int>(
        valueListenable: rebuildTick,
        // Deliberately NOT const: a canonicalized const widget is
        // `identical()` across rebuilds, so Flutter's Element.update skips
        // `didUpdateWidget` entirely — this test needs a genuinely new
        // instance each rebuild, exactly like the real IndexedStack demo's
        // `NativeAdWidget(active: _tabIndex == 1)` is.
        builder: (context, tick, __) => NativeAdWidget(active: tick >= 0),
      )));
      await tester.pump(const Duration(milliseconds: 50));
      expect(adapter.loadNativeCalls, 1);

      // Close then reopen the gate: _onCanRequestAdsChanged schedules a
      // post-frame _initNative() (still `_allowed == false` at this point).
      AdManager().debugCanRequestAds = false;
      await tester.pump(const Duration(milliseconds: 50));
      AdManager().debugCanRequestAds = true;

      // Before that scheduled callback fires, an unrelated parent rebuild
      // hands this State a brand new NativeAdWidget instance (active still
      // true) — didUpdateWidget fires SYNCHRONOUSLY, during this same
      // frame's build phase, i.e. strictly before the post-frame callback.
      rebuildTick.value++;
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadNativeCalls, 2,
          reason: 'T154 (codex re-review, P1) — exactly one real reload for '
              'one gate-reopen event: didUpdateWidget\'s synchronous reload '
              'must win and the already-queued post-frame callback must '
              'back off once `_allowed` is already true, not double-load');
      expect(tester.takeException(), isNull);
    });

    testWidgets('active:true (the default) behaves exactly as before',
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

      await tester.pumpWidget(host(const NativeAdWidget(active: true)));
      await tester.pump(const Duration(milliseconds: 50));

      expect(adapter.loadNativeCalls, 1);
      expect(tester.takeException(), isNull);
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
