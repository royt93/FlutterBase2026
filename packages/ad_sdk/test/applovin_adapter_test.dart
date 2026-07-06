// Behavioural tests for AppLovinAdapter, driven through the injectable
// AppLovinBridge. A FakeAppLovinBridge captures the listeners the adapter wires
// and records load/show calls, so we can fire native-style callbacks and assert
// the adapter's slot transitions, the reload-after-display-fail fix, and the
// reward earned-vs-dismissed logic — all without the real AppLovin SDK.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures listeners + records every native call.
class FakeAppLovinBridge implements AppLovinBridge {
  AppOpenAdListener? appOpen;
  InterstitialListener? inter;
  RewardedAdListener? rewarded;
  WidgetAdViewAdListener? widget;

  final List<String> loadAppOpenCalls = [];
  final List<String> showAppOpenCalls = [];
  final List<String> loadInterCalls = [];
  final List<String> showInterCalls = [];
  final List<String> loadRewardedCalls = [];
  final List<String> showRewardedCalls = [];

  @override
  Future<void> initialize(String sdkKey) async {}
  @override
  void setTestDeviceAdvertisingIds(List<String> ids) {}

  bool termsFlowEnabled = true;
  @override
  void setTermsAndPrivacyPolicyFlowEnabled(bool enabled) =>
      termsFlowEnabled = enabled;
  @override
  void setAppOpenAdListener(AppOpenAdListener? l) => appOpen = l;
  @override
  void setInterstitialListener(InterstitialListener? l) => inter = l;
  @override
  void setRewardedAdListener(RewardedAdListener? l) => rewarded = l;
  @override
  void setWidgetAdViewAdListener(WidgetAdViewAdListener? l) => widget = l;
  @override
  void loadAppOpenAd(String id) => loadAppOpenCalls.add(id);
  @override
  void showAppOpenAd(String id) => showAppOpenCalls.add(id);
  @override
  void loadInterstitial(String id) => loadInterCalls.add(id);
  @override
  void showInterstitial(String id) => showInterCalls.add(id);
  @override
  void loadRewardedAd(String id) => loadRewardedCalls.add(id);
  @override
  void showRewardedAd(String id) => showRewardedCalls.add(id);
  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) async => 1;
  @override
  Future<void> destroyWidgetAdView(AdViewId id) async {}
}

MaxAd _fakeAd() => MaxAd('unit', 'APPOPEN', null, 'net', '', 0.0, 'exact',
    'cid', 'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0), null, null);

MaxError _fakeError() => MaxError(ErrorCode.values.first, 'fail', null, null);

const _config = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'sdk',
    bannerId: 'banner-id',
    interstitialId: 'inter-id',
    appOpenId: 'appopen-id',
    rewardedId: 'rewarded-id',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAppLovinBridge bridge;
  late AppLovinAdapter adapter;

  setUp(() async {
    bridge = FakeAppLovinBridge();
    adapter = AppLovinAdapter(bridge: bridge);
    final ok = await adapter.initialize(_config);
    expect(ok, isTrue);
    expect(bridge.appOpen, isNotNull, reason: 'listeners wired during init');
  });

  tearDown(() async {
    await adapter.dispose();
  });

  group('AppLovin CMP flow vs UMP (T01)', () {
    test('default config disables AppLovin CMP flow (UMP is the CMP)', () {
      // setUp initialised with the default _config (disableAppLovinCmpFlow=true).
      expect(bridge.termsFlowEnabled, isFalse);
    });

    test('disableAppLovinCmpFlow:false keeps AppLovin CMP flow enabled',
        () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(const AdConfig(
        provider: AdProvider.appLovin,
        disableAppLovinCmpFlow: false,
        appLovin: AppLovinConfig(
          sdkKey: 'sdk',
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'a',
          rewardedId: 'r',
        ),
      ));
      expect(b.termsFlowEnabled, isTrue);
      await a.dispose();
    });
  });

  group('App Open load/show happy path', () {
    test('load → onAdLoaded marks slot ready and fires callback(true)',
        () async {
      bool? loaded;
      await adapter.loadAppOpen(onAdLoaded: (v) => loaded = v);
      expect(bridge.loadAppOpenCalls, ['appopen-id']);
      expect(adapter.appOpenSlot.isLoading, isTrue);

      bridge.appOpen!.onAdLoadedCallback(_fakeAd());
      expect(adapter.appOpenSlot.isReady, isTrue);
      expect(loaded, isTrue);
    });
  });

  group('App Open reload-after-display-fail (regression for the backoff bug)',
      () {
    test('display failure refills immediately via beginReload', () async {
      // Load + ready.
      await adapter.loadAppOpen();
      bridge.appOpen!.onAdLoadedCallback(_fakeAd());
      expect(adapter.appOpenSlot.isReady, isTrue);

      // Show.
      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);
      expect(bridge.showAppOpenCalls, ['appopen-id']);
      expect(adapter.appOpenSlot.isShowing, isTrue);
      final loadsBefore = bridge.loadAppOpenCalls.length;

      // Native display failure → caller dismissed(false) AND a fresh load is
      // kicked immediately (the bug: beginLoad was blocked by the cooldown the
      // show-failure just armed, so no reload happened).
      bridge.appOpen!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());

      expect(dismissed, isFalse);
      expect(bridge.loadAppOpenCalls.length, loadsBefore + 1,
          reason: 'reload must fire despite the show-failure cooldown');
    });

    test('normal hide dismisses(true) and reloads', () async {
      await adapter.loadAppOpen();
      bridge.appOpen!.onAdLoadedCallback(_fakeAd());
      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);
      final loadsBefore = bridge.loadAppOpenCalls.length;

      bridge.appOpen!.onAdHiddenCallback(_fakeAd());

      expect(dismissed, isTrue);
      expect(bridge.loadAppOpenCalls.length, loadsBefore + 1);
    });
  });

  group('Rewarded earned vs dismissed', () {
    Future<void> loadAndShow(void Function(RewardResult) onDone) async {
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(_fakeAd());
      expect(adapter.rewardedSlot.isReady, isTrue);
      await adapter.showRewarded(onDone: onDone);
      expect(bridge.showRewardedCalls, ['rewarded-id']);
    }

    test('receiving a reward yields earned=true', () async {
      RewardResult? result;
      await loadAndShow((r) => result = r);
      bridge.rewarded!
          .onAdReceivedRewardCallback(_fakeAd(), MaxReward(10, 'c'));
      expect(result, isNotNull);
      expect(result!.earned, isTrue);
    });

    test('hiding without a reward yields skipped (not earned)', () async {
      RewardResult? result;
      await loadAndShow((r) => result = r);
      bridge.rewarded!.onAdHiddenCallback(_fakeAd());
      expect(result, isNotNull);
      expect(result!.earned, isFalse);
    });
  });

  group('Interstitial reload-after-display-fail', () {
    test('display failure refills immediately', () async {
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(_fakeAd());
      expect(adapter.interstitialSlot.isReady, isTrue);

      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());

      expect(shown, isFalse);
      expect(bridge.loadInterCalls.length, loadsBefore + 1,
          reason: 'interstitial must refill past the show-failure cooldown');
    });
  });

  // End-to-end: go through the REAL showAppOpen path (which arms the watchdog)
  // and then advance time with FakeAsync — closing the seam between "showAppOpen
  // arms the watchdog" and "the watchdog timing logic".
  group('showAppOpen arms the watchdog (real show path + FakeAsync)', () {
    AppLovinAdapter armedViaRealShow(
      FakeAppLovinBridge b,
      AppLifecycleState lifecycle,
      FakeAsync async,
      void Function(bool) onDismiss,
    ) {
      final a = AppLovinAdapter(
        bridge: b,
        lifecycleStateResolver: () => lifecycle,
      );
      a.initialize(_config);
      async.flushMicrotasks();
      a.loadAppOpen();
      b.appOpen!.onAdLoadedCallback(_fakeAd());
      a.showAppOpen(onDismiss: onDismiss);
      async.flushMicrotasks();
      expect(b.showAppOpenCalls, ['appopen-id']);
      expect(a.appOpenSlot.isShowing, isTrue);
      return a;
    }

    test('iOS: real show → re-arms past 10s, only the 90s hard cap dismisses',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fakeAsync((async) {
        final b = FakeAppLovinBridge();
        var calls = 0;
        bool? dismissed;
        final a = armedViaRealShow(b, AppLifecycleState.resumed, async, (d) {
          calls++;
          dismissed = d;
        });

        async.elapse(const Duration(seconds: 30));
        expect(dismissed, isNull,
            reason: 'iOS re-arms; no early force-dismiss');

        async.elapse(const Duration(seconds: 70)); // total 100s > 90s
        expect(dismissed, isFalse, reason: 'hard cap fires');
        expect(calls, 1);
        expect(a.appOpenSlot.value, AdSlotState.cooldown);
      });
      debugDefaultTargetPlatformOverride = null;
    });

    test('native hide cancels the armed watchdog (no late double-dismiss)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeAsync((async) {
        final b = FakeAppLovinBridge();
        var calls = 0;
        bool? dismissed;
        armedViaRealShow(b, AppLifecycleState.resumed, async, (d) {
          calls++;
          dismissed = d;
        });

        // AppLovin's native onAdHidden resolves the show.
        b.appOpen!.onAdHiddenCallback(_fakeAd());
        expect(dismissed, isTrue);
        expect(calls, 1);

        // Past the hard cap — the cancelled watchdog must not fire again.
        async.elapse(const Duration(seconds: 100));
        expect(calls, 1, reason: 'watchdog cancelled by native hide');
      });
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
