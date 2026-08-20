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
  String? lastShowRewardedCustomData;

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
  void showRewardedAd(String id, {String? customData}) {
    showRewardedCalls.add(id);
    lastShowRewardedCustomData = customData;
  }

  final List<AdViewId> destroyWidgetAdViewCalls = [];

  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) async => 1;
  @override
  Future<void> destroyWidgetAdView(AdViewId id) async {
    destroyWidgetAdViewCalls.add(id);
  }
}

/// FakeAppLovinBridge's preloadWidgetAdView always returns the constant
/// adViewId `1`, which hides M5-style bugs (old-id-equals-new-id looks like
/// a no-op). This variant hands out a fresh id per call, like the real
/// native bridge does.
class _IncrementingIdBridge extends FakeAppLovinBridge {
  int _next = 1;
  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) async =>
      _next++;
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

  group('COPPA child-user init gate (T40)', () {
    test('isAgeRestrictedUser:true aborts init and skips native bridge',
        () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      final ok = await a.initialize(_config, isAgeRestrictedUser: true);
      expect(ok, isFalse);
      expect(a.isInitialised, isFalse);
      expect(a.disabledForChildUser, isTrue);
      expect(b.appOpen, isNull, reason: 'listeners never wired');
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

  // 2026-08-16 audit: the adapter-internal reloads above call the native
  // bridge DIRECTLY (bypassing AdManager.loadX(), which is the only place a
  // load watchdog otherwise gets armed — see the comment right below on
  // canReload). If AppLovin's native SDK never calls back for one of these
  // specific reloads, the slot would stay stuck `loading` forever with
  // nothing to recover it. AdSlot.armLoadWatchdog must be armed directly at
  // each of these reload sites too.
  group('Load watchdog on adapter-internal reload (no AdManager in the loop)',
      () {
    test('appOpen: reload-after-display-fail recovers via watchdog if the '
        'native callback never arrives', () {
      fakeAsync((async) {
        adapter.loadAppOpen();
        async.flushMicrotasks();
        bridge.appOpen!.onAdLoadedCallback(_fakeAd());
        adapter.showAppOpen(onDismiss: (_) {});
        async.flushMicrotasks();

        // Triggers the internal reload — bridge.loadAppOpenAd is called
        // again, but we deliberately never fire another callback for it.
        bridge.appOpen!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());
        expect(adapter.appOpenSlot.isLoading, isTrue);

        async.elapse(const Duration(seconds: 29));
        expect(adapter.appOpenSlot.isLoading, isTrue,
            reason: 'watchdog must not fire before its 30s timeout');

        async.elapse(const Duration(seconds: 2));
        expect(adapter.appOpenSlot.isLoading, isFalse,
            reason: 'watchdog must force the slot out of loading once the '
                'native callback never arrives — otherwise it is stuck '
                'forever');
      });
    });

    test('interstitial: reload-after-display-fail recovers via watchdog if '
        'the native callback never arrives', () {
      fakeAsync((async) {
        adapter.loadInterstitial();
        async.flushMicrotasks();
        bridge.inter!.onAdLoadedCallback(_fakeAd());
        adapter.showInterstitial(onDone: (_) {});
        async.flushMicrotasks();

        bridge.inter!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());
        expect(adapter.interstitialSlot.isLoading, isTrue);

        async.elapse(const Duration(seconds: 31));
        expect(adapter.interstitialSlot.isLoading, isFalse,
            reason: 'watchdog must force the slot out of loading');
      });
    });

    test('rewarded: reload-after-display-fail recovers via watchdog if the '
        'native callback never arrives', () {
      fakeAsync((async) {
        adapter.loadRewarded();
        async.flushMicrotasks();
        bridge.rewarded!.onAdLoadedCallback(_fakeAd());
        adapter.showRewarded(onDone: (_) {});
        async.flushMicrotasks();

        bridge.rewarded!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());
        expect(adapter.rewardedSlot.isLoading, isTrue);

        async.elapse(const Duration(seconds: 31));
        expect(adapter.rewardedSlot.isLoading, isFalse,
            reason: 'watchdog must force the slot out of loading');
      });
    });
  });

  // T-canReload: adapter-internal reload-on-dismiss/reload-on-fail paths call
  // the native bridge directly, bypassing AdManager's load*() gate methods
  // entirely. AdManager wires `canReload` to those same VIP/daily-cap/
  // consent/connectivity checks — when it reports false, the reload must be
  // skipped (not just retried later): a VIP member's fullscreen ad dismissing
  // must never silently trigger a fresh load behind their back.
  group('canReload gate blocks adapter-internal auto-reload', () {
    test('appOpen: hidden does not reload when canReload is false', () async {
      adapter.canReload = () => false;
      await adapter.loadAppOpen();
      bridge.appOpen!.onAdLoadedCallback(_fakeAd());
      expect(adapter.appOpenSlot.isReady, isTrue);
      await adapter.showAppOpen(onDismiss: (_) {});
      final loadsBefore = bridge.loadAppOpenCalls.length;

      bridge.appOpen!.onAdHiddenCallback(_fakeAd());

      expect(bridge.loadAppOpenCalls.length, loadsBefore,
          reason: 'gate closed — must not reload behind the caller\'s back');
    });

    test('appOpen: display failure does not reload when canReload is false',
        () async {
      adapter.canReload = () => false;
      await adapter.loadAppOpen();
      bridge.appOpen!.onAdLoadedCallback(_fakeAd());
      await adapter.showAppOpen(onDismiss: (_) {});
      final loadsBefore = bridge.loadAppOpenCalls.length;

      bridge.appOpen!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());

      expect(bridge.loadAppOpenCalls.length, loadsBefore);
    });

    test('interstitial: hidden does not reload when canReload is false',
        () async {
      adapter.canReload = () => false;
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(_fakeAd());
      await adapter.showInterstitial(onDone: (_) {});
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdHiddenCallback(_fakeAd());

      expect(bridge.loadInterCalls.length, loadsBefore);
    });

    test(
        'interstitial: display failure does not reload when canReload is false',
        () async {
      adapter.canReload = () => false;
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(_fakeAd());
      await adapter.showInterstitial(onDone: (_) {});
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());

      expect(bridge.loadInterCalls.length, loadsBefore);
    });

    test('rewarded: hidden does not reload when canReload is false', () async {
      adapter.canReload = () => false;
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(_fakeAd());
      await adapter.showRewarded(onDone: (_) {});
      final loadsBefore = bridge.loadRewardedCalls.length;

      bridge.rewarded!.onAdHiddenCallback(_fakeAd());

      expect(bridge.loadRewardedCalls.length, loadsBefore);
    });

    test('rewarded: display failure does not reload when canReload is false',
        () async {
      adapter.canReload = () => false;
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(_fakeAd());
      await adapter.showRewarded(onDone: (_) {});
      final loadsBefore = bridge.loadRewardedCalls.length;

      bridge.rewarded!.onAdDisplayFailedCallback(_fakeAd(), _fakeError());

      expect(bridge.loadRewardedCalls.length, loadsBefore);
    });

    test('interstitial: reloads normally when canReload stays true (default)',
        () async {
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(_fakeAd());
      await adapter.showInterstitial(onDone: (_) {});
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdHiddenCallback(_fakeAd());

      expect(bridge.loadInterCalls.length, loadsBefore + 1);
    });
  });

  group('repeated-failure warning log (T44)', () {
    final captured = <String>[];

    setUp(() {
      captured.clear();
      SafeLogger.configure(
        level: AdLogLevel.warning,
        onLog: (level, tag, message) => captured.add(message),
      );
    });

    tearDown(() => SafeLogger.resetForTest());

    test('fires exactly once, on the 3rd consecutive load failure', () async {
      await adapter.loadInterstitial();

      bridge.inter!.onAdLoadFailedCallback('inter-id', _fakeError());
      expect(
          captured.any((m) => m.contains('consecutive load failures')), isFalse,
          reason: '1st failure — too early');

      bridge.inter!.onAdLoadFailedCallback('inter-id', _fakeError());
      expect(
          captured.any((m) => m.contains('consecutive load failures')), isFalse,
          reason: '2nd failure — still too early');

      bridge.inter!.onAdLoadFailedCallback('inter-id', _fakeError());
      expect(captured.where((m) => m.contains('consecutive load failures')),
          hasLength(1),
          reason: '3rd failure — threshold hit, logs exactly once');

      bridge.inter!.onAdLoadFailedCallback('inter-id', _fakeError());
      expect(captured.where((m) => m.contains('consecutive load failures')),
          hasLength(1),
          reason: '4th failure — must not log again (== not >=)');
    });

    test('re-fires on a fresh streak after a success resets the counter',
        () async {
      await adapter.loadInterstitial();
      for (var i = 0; i < 3; i++) {
        bridge.inter!.onAdLoadFailedCallback('inter-id', _fakeError());
      }
      expect(captured.where((m) => m.contains('consecutive load failures')),
          hasLength(1));

      bridge.inter!.onAdLoadedCallback(_fakeAd());
      captured.clear();

      for (var i = 0; i < 3; i++) {
        bridge.inter!.onAdLoadFailedCallback('inter-id', _fakeError());
      }
      expect(captured.where((m) => m.contains('consecutive load failures')),
          hasLength(1),
          reason: 'success resets consecutiveFailures — streak counts fresh');
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

  group('AppLovinAdapter.dispose() releases ValueNotifiers', () {
    test('slot and banner notifiers are disposed, not just reset', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      await a.dispose();

      expect(() => a.appOpenSlot.state.addListener(() {}), throwsFlutterError);
      expect(() => a.interstitialSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(() => a.rewardedSlot.state.addListener(() {}), throwsFlutterError);
      expect(() => a.bannerSlot('k').state.addListener(() {}),
          throwsFlutterError);
      expect(() => a.banner('k').isLoaded.addListener(() {}),
          throwsFlutterError);
      expect(() => a.appLovinBannerAdViewId('k').addListener(() {}),
          throwsFlutterError);
      expect(() => a.mrecSlot('k').state.addListener(() {}),
          throwsFlutterError);
      expect(() => a.mrec('k').isLoaded.addListener(() {}),
          throwsFlutterError);
      expect(() => a.appLovinMrecAdViewId('k').addListener(() {}),
          throwsFlutterError);
      expect(() => a.nativeSlot('k').state.addListener(() {}),
          throwsFlutterError);
      expect(() => a.native('k').isLoaded.addListener(() {}),
          throwsFlutterError);
    });
  });

  group('AppLovinAdapter native (no-op preload)', () {
    test('preloadNative() is a no-op — MaxNativeAdView loads on mount',
        () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);

      await a.preloadNative('k');
      expect(a.native('k').isLoaded.value, isFalse);
      expect(a.native('k').hasError.value, isFalse);
      expect(a.buildAdmobNativeView('k'), isNull);
      expect(a.appLovinNativeId, ''); // _config sets no nativeId
    });

    // T65 (phase 1) — two simultaneous NativeAdWidgets on AppLovin must not
    // share isLoaded/hasError: before this fix both widgets read/wrote the
    // same single BannerListenables bundle, so one ad finishing (or
    // failing) would flip the OTHER widget's shimmer state too.
    test('two different keys get independent BannerListenables', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);

      a.native('a').isLoaded.value = true;

      expect(a.native('b').isLoaded.value, isFalse,
          reason: 'key "b" must not see key "a" isLoaded=true');
    });

    // 2026-08-16 audit: MaxNativeAdView's listener callbacks (native_ad_widget
    // .dart) re-resolve adapter.native(instanceKey) on EVERY invocation, not
    // just once at load start — so a callback arriving after
    // disposeNativeInstance(key) must NOT silently resurrect a brand new,
    // never-disposed BannerListenables for that permanently-gone key. That
    // would leak one live ValueNotifier bundle per native ad a ListView
    // scrolls past (T73's exact in-feed use case).
    test('a key looked up again after disposeNativeInstance() never gets a '
        'fresh live BannerListenables (no resurrection leak)', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);

      final key = Object();
      a.native(key).isLoaded.value = true; // materializes a live entry
      a.disposeNativeInstance(key);

      // A late callback (post-dispose) looking the key up again must get an
      // ALREADY-disposed bundle back, not a fresh live one — proven by the
      // write throwing, exactly like every other "disposed mid-flight" path
      // this adapter already handles (see the try/catch in
      // native_ad_widget.dart's onAdLoadedCallback).
      expect(() => a.native(key).isLoaded.value = true, throwsA(anything),
          reason: 'looking up an already-disposed key must never silently '
              'allocate a new, permanently-unreachable live listenables '
              'bundle');
    });
  });

  group('onAppResumed() recreates errored banner AdView (T34)', () {
    test('destroys the stale native AdView before preloading a replacement',
        () async {
      await adapter.preloadBanner('k');
      final oldId = adapter.appLovinBannerAdViewId('k').value;
      expect(oldId, isNotNull, reason: 'fake bridge preloads id=1');

      adapter.banner('k').hasError.value = true;
      adapter.onAppResumed();
      await Future<void>.value(); // flush unawaited destroyWidgetAdView

      expect(bridge.destroyWidgetAdViewCalls, [oldId],
          reason: 'stale AdView must be destroyed exactly once, with the '
              'id that was current before the error-triggered recreate');
      expect(adapter.banner('k').hasError.value, isFalse);
      expect(bridge.loadInterCalls, isEmpty,
          reason: 'sanity: only banner path touched');
    });

    // T65 (phase 2) — onAppResumed must recover EVERY known banner key that
    // errored, not just one shared slot.
    test('recovers multiple errored keys independently, leaves healthy '
        'keys alone', () async {
      await adapter.preloadBanner('a');
      await adapter.preloadBanner('b');
      await adapter.preloadBanner('healthy');
      final oldA = adapter.appLovinBannerAdViewId('a').value;
      final oldB = adapter.appLovinBannerAdViewId('b').value;

      adapter.banner('a').hasError.value = true;
      adapter.banner('b').hasError.value = true;
      adapter.onAppResumed();
      await Future<void>.value();

      expect(bridge.destroyWidgetAdViewCalls, containsAll([oldA, oldB]));
      expect(adapter.banner('a').hasError.value, isFalse);
      expect(adapter.banner('b').hasError.value, isFalse);
      expect(adapter.banner('healthy').hasError.value, isFalse,
          reason: 'a key that never errored must be untouched');
    });
  });

  // M5 (audit_claude.md, 2026-08-20): preloadBanner/preloadMrec can be
  // called again for a key that already has a live adViewId — VIP-expiry
  // preload (_onVipActiveChanged) and connectivity-restore refill
  // (_onConnectivityChanged) both re-nudge the shared warmup key
  // unconditionally, unlike onAppResumed's error-recovery path above which
  // nulls the notifier first. Overwriting the notifier without destroying
  // the old native AdView leaked it, independent of B1.
  group('preloadBanner/preloadMrec re-preload with an already-live adViewId '
      '(M5)', () {
    test('preloadBanner destroys the previous adViewId instead of just '
        'overwriting it', () async {
      final b = _IncrementingIdBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);

      await a.preloadBanner('k');
      final oldId = a.appLovinBannerAdViewId('k').value;
      expect(oldId, isNotNull);

      await a.preloadBanner('k');
      final newId = a.appLovinBannerAdViewId('k').value;
      await Future<void>.value(); // flush unawaited destroyWidgetAdView

      expect(newId, isNot(oldId));
      expect(b.destroyWidgetAdViewCalls, [oldId],
          reason: 're-preloading a key with a live adViewId must destroy '
              'the stale native AdView, not just orphan it');
    });

    test('preloadMrec destroys the previous adViewId instead of just '
        'overwriting it', () async {
      final b = _IncrementingIdBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(const AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'sdk',
          bannerId: 'banner-id',
          interstitialId: 'inter-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
          mrecId: 'mrec-id',
        ),
      ));
      addTearDown(a.dispose);

      await a.preloadMrec('k');
      final oldId = a.appLovinMrecAdViewId('k').value;
      expect(oldId, isNotNull);

      await a.preloadMrec('k');
      final newId = a.appLovinMrecAdViewId('k').value;
      await Future<void>.value();

      expect(newId, isNot(oldId));
      expect(b.destroyWidgetAdViewCalls, [oldId],
          reason: 're-preloading a key with a live adViewId must destroy '
              'the stale native AdView, not just orphan it');
    });
  });

  // 2026-08-19 audit (Finding 5): disposeBannerInstance/disposeMrecInstance
  // disposed only the Dart-side AdSlot/BannerListenables/ValueNotifier —
  // they never called destroyWidgetAdView, so every BannerAdWidget/
  // MrecAdWidget that permanently unmounts leaked its native MaxAdView.
  group('disposeBannerInstance/disposeMrecInstance destroy the native '
      'AdView (2026-08-19 audit)', () {
    test('disposeBannerInstance destroys the native AdView, not just the '
        'Dart-side state', () async {
      await adapter.preloadBanner('k');
      final id = adapter.appLovinBannerAdViewId('k').value;
      expect(id, isNotNull, reason: 'fake bridge preloads id=1');

      adapter.disposeBannerInstance('k');
      await Future<void>.value(); // flush unawaited destroyWidgetAdView

      expect(bridge.destroyWidgetAdViewCalls, [id],
          reason: 'permanently disposing a BannerAdWidget instance must '
              'release its native AdView, not just the Dart-side state');
    });

    test('disposeMrecInstance destroys the native AdView, not just the '
        'Dart-side state', () async {
      // Local adapter/config: the shared top-level `_config` has no
      // mrecId, so the shared `adapter` always no-ops preloadMrec.
      final mrecBridge = FakeAppLovinBridge();
      final mrecAdapter = AppLovinAdapter(bridge: mrecBridge);
      await mrecAdapter.initialize(const AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'sdk',
          bannerId: 'banner-id',
          interstitialId: 'inter-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
          mrecId: 'mrec-id',
        ),
      ));
      addTearDown(mrecAdapter.dispose);

      await mrecAdapter.preloadMrec('k');
      final id = mrecAdapter.appLovinMrecAdViewId('k').value;
      expect(id, isNotNull, reason: 'fake bridge preloads id=1');

      mrecAdapter.disposeMrecInstance('k');
      await Future<void>.value();

      expect(mrecBridge.destroyWidgetAdViewCalls, [id],
          reason: 'permanently disposing a MrecAdWidget instance must '
              'release its native AdView, not just the Dart-side state');
    });
  });

  group('AppLovinAdapter mrec (keyed)', () {
    // T65 (phase 3) — same guarantee as banner: two different MrecAdWidget
    // keys must not share BannerListenables.
    test('two different keys get independent BannerListenables', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);

      a.mrec('a').isLoaded.value = true;

      expect(a.mrec('b').isLoaded.value, isFalse,
          reason: 'key "b" must not see key "a" isLoaded=true');
    });
  });
}
