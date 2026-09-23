// On-device integration test for round-38 audit MAJOR-1 — an AppLovin
// native ad that fails to load once must recover on the next retry, not
// stay permanently blank for the widget's remaining lifetime.
//
// Why this uses `AdManager.debugAdapterFactory` (a fake provider) instead of
// a real AppLovin native ad: reproducing a real native-ad load failure
// deterministically needs either a real AppLovin SDK key this session does
// not have (`APPLOVIN_SDK_KEY`, supplied via `--dart-define` and never
// committed — see `example/lib/main.dart`) plus an ad unit guaranteed to
// fail, or waiting on real network conditions this suite has never
// controlled for any other test either. What the fix actually touches
// (`NativeAdWidget._onNativeErrorChanged` calling
// `AdManager().disposeNativeInstance(this)`) is 100% Dart-side — no native
// dependency — so a fake provider still exercises the REAL `AdManager`
// singleton, the REAL `NativeAdWidget`/State lifecycle, and a REAL 30-second
// wall-clock `Timer`, all running on real hardware. Only the native SDK's
// own load attempt is faked, which is the one part neither a real key nor a
// real device would make any more "real" for what this fix changes.
//
// Widget-level coverage of the same fix (mocked in a plain `flutter test`,
// no device): test/native_ad_widget_test.dart.
//
// This test genuinely takes >30s (the real retry timer, not a fake clock).
//
// Run with:
//   flutter test integration_test/round38_native_ad_error_retry_test.dart -d <device>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _FakeAppLovinAdapter implements AdProviderAdapter {
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

  final nativeSlotsByKey = <Object, AdSlot>{};
  final nativeListenablesByKey = <Object, BannerListenables>{};
  int loadNativeCalls = 0;

  void Function(AdEvent)? _eventSink;
  @override
  void Function(AdEvent)? get eventSink => _eventSink;
  @override
  set eventSink(void Function(AdEvent)? sink) => _eventSink = sink;

  bool Function() _canReload = () => true;
  @override
  bool Function() get canReload => _canReload;
  @override
  set canReload(bool Function() gate) => _canReload = gate;

  @override
  Future<bool> initialize(AdConfig config,
      {String deviceGaid = '',
      bool isAgeRestrictedUser = false,
      AdConsent? consent}) async {
    return true;
  }

  @override
  Future<void> dispose() async {}

  @override
  void applyConsent(AdConsent consent) {}

  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {}
  @override
  Future<void> loadMrecIfNeeded(Object key, double widthPx) async {}
  @override
  void onAppPaused() {}
  @override
  void onAppResumed() {}
  @override
  Future<void> discardCachedFullscreenAds() async {}
  @override
  String? get appLovinNativeId => 'fake-native-id';
  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}

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
  String get tag => 'fake-round38';
  @override
  Future<void> preloadNative(Object key,
      {TemplateType templateType = TemplateType.medium}) async {
    loadNativeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

AdConfig _appLovinConfig() => const AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(
        sdkKey: 'fake-sdk-key-not-used-by-fake-adapter',
        bannerId: 'fake-banner',
        interstitialId: 'fake-inter',
        appOpenId: 'fake-appopen',
        rewardedId: 'fake-rewarded',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAppLovinAdapter adapter;

  setUp(() {
    adapter = _FakeAppLovinAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    // Explicit opt-in (2026-09-23) — this fake adapter never runs real
    // native AppLovinSdk init, so the real MaxNativeAdView would NPE deep
    // inside AppLovin's own native SDK once the 30s retry timer below fires.
    // See AdManager.debugForceSkipRealAppLovinNativeView's doc for why this
    // isn't inferred from the adapter's type instead.
    AdManager.debugForceSkipRealAppLovinNativeView = true;
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    AdManager.debugForceSkipRealAppLovinNativeView = false;
    await AdManager().destroy();
  });

  testWidgets(
      'an AppLovin native ad that errors once recovers on the real 30s '
      'retry timer instead of staying blank forever (round-38 MAJOR-1)',
      (tester) async {
    await AdManager()
        .initialize(config: _appLovinConfig(), onComplete: (_, __) {});
    await AdManager().vip?.revokeAll();

    // Real connectivity plugin can take a beat to resolve its first read on
    // a real device — wait for it rather than assuming instant readiness.
    for (var i = 0; i < 20 && !AdManager().isConnected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: const NativeAdWidget())),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    if (adapter.nativeListenablesByKey.isEmpty) {
      // Give the widget's own connectivity-gated init another window.
      for (var i = 0; i < 20 && adapter.nativeListenablesByKey.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    expect(adapter.nativeListenablesByKey, isNotEmpty,
        reason: 'sanity: the widget must have mounted and requested a '
            'native bundle for real');
    final firstBundle = adapter.nativeListenablesByKey.values.first;

    // The native ad fails to load once (transient no-fill/network blip).
    firstBundle.hasError.value = true;
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.getSize(find.byType(NativeAdWidget)).height, 0,
        reason: 'collapses while hasError is true, same as pre-fix');

    // 2026-09-23 — now automated past this point. Previously the real 30s
    // retry firing led to the real AppLovin native platform view mounting
    // (no real SDK key committed here) and crashing the Android platform-
    // view channel, corrupting LiveTestWidgetsFlutterBinding's own frame
    // state. Fixed at the SDK level: setUp() above opts into
    // `AdManager.debugForceSkipRealAppLovinNativeView` (guarded the same way
    // as `debugAdapterFactory` — always false outside debug/test), which
    // lets `NativeAdWidget._buildAppLovin()` skip the real
    // `_AppLovinMaxNativeView` and render an empty box instead. Real
    // wall-clock wait — this genuinely takes >30s.
    bool freshBundle() =>
        adapter.nativeListenablesByKey.isNotEmpty &&
        !identical(adapter.nativeListenablesByKey.values.first, firstBundle);
    for (var i = 0; i < 130 && !freshBundle(); i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(freshBundle(), isTrue,
        reason: 'the real 30s retry timer must dispose the stale bundle and '
            'request a fresh one, not stay permanently blank (round-38 '
            'MAJOR-1)');
    expect(adapter.nativeListenablesByKey.values.first.hasError.value, isFalse,
        reason: 'the fresh bundle must start clean, not still carrying the '
            'old error');
    expect(tester.takeException(), isNull,
        reason: 'the retry must not crash mounting the (fake-adapter-'
            'skipped) native view');
  });
}
