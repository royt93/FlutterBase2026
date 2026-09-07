// Behavioural tests for AppLovinAdapter, driven through the injectable
// AppLovinBridge. A FakeAppLovinBridge captures the listeners the adapter wires
// and records load/show calls, so we can fire native-style callbacks and assert
// the adapter's slot transitions, the reload-after-display-fail fix, and the
// reward earned-vs-dismissed logic — all without the real AppLovin SDK.

import 'dart:async';

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

  /// MJ1 — ordered log of the privacy/init calls, so a test can assert that
  /// consent reaches MAX *before* SDK init rather than after it.
  final List<String> initOrder = [];

  @override
  Future<void> initialize(String sdkKey) async => initOrder.add('initialize');
  @override
  void setHasUserConsent(bool hasConsent) =>
      initOrder.add('setHasUserConsent($hasConsent)');
  @override
  void setDoNotSell(bool doNotSell) =>
      initOrder.add('setDoNotSell($doNotSell)');
  List<String>? capturedTestDeviceAdvertisingIds;
  @override
  void setTestDeviceAdvertisingIds(List<String> ids) {
    capturedTestDeviceAdvertisingIds = ids;
    initOrder.add('setTestDeviceAdvertisingIds($ids)');
  }

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

/// Round-6 QC — counts native preload requests, which is the only thing that
/// actually distinguishes "retry skipped" from "retry sent with the slot left
/// in cooldown": the slot ends up in cooldown either way, so asserting on slot
/// state cannot see the bug.
class _CountingPreloadBridge extends FakeAppLovinBridge {
  int preloadCalls = 0;
  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) async {
    preloadCalls++;
    return 1;
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

/// Round-7 audit, MAJOR — lets a test unmount the owning widget *while*
/// preloadWidgetAdView is still in flight, the window in which the adapter
/// used to resurrect a disposed key and leak the native AdView it was handed.
class _DeferredPreloadBridge extends FakeAppLovinBridge {
  final Completer<AdViewId?> gate = Completer<AdViewId?>();
  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) => gate.future;
}

/// m22 — the native side rejects destroyWidgetAdView while the AdView is
/// still attached, which is what arms the retry chain in the first place.
class _FailingDestroyBridge extends FakeAppLovinBridge {
  @override
  Future<void> destroyWidgetAdView(AdViewId id) async {
    destroyWidgetAdViewCalls.add(id);
    throw StateError('native refused: AdView still has a container view');
  }
}

/// Round-25 QC round 16 (`codex`, MAJOR) — lets a test park `dispose()` inside
/// its per-AdView `destroyWidgetAdView` await, which is the window in which an
/// in-flight `preloadBanner` used to insert into the very map `dispose()` was
/// iterating.
class _TeardownRaceBridge extends FakeAppLovinBridge {
  int _next = 1;
  final Completer<AdViewId?> racePreload = Completer<AdViewId?>();
  final Completer<void> destroyGate = Completer<void>();

  /// The next `preloadWidgetAdView` call hangs until [racePreload] completes.
  bool deferNextPreload = false;

  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) {
    if (deferNextPreload) {
      deferNextPreload = false;
      return racePreload.future;
    }
    return Future<AdViewId?>.value(_next++);
  }

  @override
  Future<void> destroyWidgetAdView(AdViewId id) async {
    destroyWidgetAdViewCalls.add(id);
    await destroyGate.future;
  }
}

/// Round-25 QC round 17 (`codex`, MAJOR) — holds the FIRST
/// `destroyWidgetAdView` open across `dispose()` and then fails it, which is
/// the window in which the retry chain used to arm a timer that outlives the
/// adapter.
class _DeferredFailingDestroyBridge extends FakeAppLovinBridge {
  final Completer<void> firstDestroy = Completer<void>();

  @override
  Future<void> destroyWidgetAdView(AdViewId id) async {
    destroyWidgetAdViewCalls.add(id);
    if (!firstDestroy.isCompleted) {
      await firstDestroy.future;
      throw StateError('native refused: AdView still has a container view');
    }
  }
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

    // MJ1 (round 5 audit) + M5 (independent review) — the fake records call
    // order precisely so this can be asserted; before this test nothing read
    // it, which is the same "infrastructure without an assertion" trap the
    // round-5 audit was about.
    test('MJ1: privacy flags reach MAX BEFORE initialize()', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(
        await a.initialize(_config,
            consent: const AdConsent(hasUserConsent: true)),
        isTrue,
      );

      final initAt = b.initOrder.indexOf('initialize');
      final consentAt = b.initOrder.indexOf('setHasUserConsent(true)');
      final dnsAt = b.initOrder.indexOf('setDoNotSell(false)');
      expect(consentAt, isNonNegative, reason: 'consent must be forwarded');
      expect(dnsAt, isNonNegative);
      expect(initAt, isNonNegative);
      expect(consentAt, lessThan(initAt),
          reason: 'MAX documents privacy flags as init-time settings; applying '
              'them after initialize() means the first request to MAX went out '
              'without them');
      expect(dnsAt, lessThan(initAt));
      addTearDown(() => a.dispose());
    });

    // Round-30 audit (MAJOR) — verified against the real applovin_max 4.6.4
    // native plugin source (Android AppLovinMAX.java, iOS AppLovinMAX.m):
    // `setTestDeviceAdvertisingIds` only stores into a field that
    // `initialize()`'s own native config-builder reads exactly once and
    // immediately nils. Calling it after `_bridge.initialize()` has already
    // run (the pre-fix order) writes a value nothing ever reads again —
    // this device is never actually registered as a test device, same
    // ordering mistake MJ1 above was fixed for on the consent flags.
    test('test-device GAID reaches MAX BEFORE initialize() (debug builds)',
        () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config, deviceGaid: 'test-gaid-123'),
          isTrue);
      addTearDown(a.dispose);

      final initAt = b.initOrder.indexOf('initialize');
      final gaidAt = b.initOrder
          .indexOf('setTestDeviceAdvertisingIds([test-gaid-123])');
      expect(gaidAt, isNonNegative,
          reason: 'the GAID must be forwarded to the bridge');
      expect(gaidAt, lessThan(initAt),
          reason: 'the native plugin only ever reads this field once, '
              'inside initialize() itself — calling the setter after '
              'initialize() has already run registers nothing');
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
      // Round-31 audit follow-up — SAME `MaxAd` instance threaded through
      // load→show→display-failed, same as the rewarded/interstitial
      // helpers below (see their comment): the fix added ad-identity
      // tracking to App Open too, so a fresh `_fakeAd()` per callback call
      // is now (correctly) discarded as stale.
      final ad = _fakeAd();
      await adapter.loadAppOpen();
      bridge.appOpen!.onAdLoadedCallback(ad);
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
      bridge.appOpen!.onAdDisplayFailedCallback(ad, _fakeError());

      expect(dismissed, isFalse);
      expect(bridge.loadAppOpenCalls.length, loadsBefore + 1,
          reason: 'reload must fire despite the show-failure cooldown');
    });

    test('normal hide dismisses(true) and reloads', () async {
      final ad = _fakeAd();
      await adapter.loadAppOpen();
      bridge.appOpen!.onAdLoadedCallback(ad);
      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);
      final loadsBefore = bridge.loadAppOpenCalls.length;

      bridge.appOpen!.onAdHiddenCallback(ad);

      expect(dismissed, isTrue);
      expect(bridge.loadAppOpenCalls.length, loadsBefore + 1);
    });
  });

  group('Rewarded earned vs dismissed', () {
    // Round-29 audit follow-up — returns the SAME `MaxAd` instance loaded,
    // so every show-lifecycle callback below can be identity-matched
    // against it, same as the real AppLovin SDK keeps one ad object alive
    // across its whole load→show→hide lifecycle (see `_rewardedAd` in
    // applovin_adapter.dart). A fresh `_fakeAd()` per callback call used to
    // be silently accepted before the round-29 stale-callback guards
    // existed; now it would be (correctly) discarded as stale.
    Future<MaxAd> loadAndShow(void Function(RewardResult) onDone) async {
      final ad = _fakeAd();
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(ad);
      expect(adapter.rewardedSlot.isReady, isTrue);
      await adapter.showRewarded(onDone: onDone);
      expect(bridge.showRewardedCalls, ['rewarded-id']);
      return ad;
    }

    test('receiving a reward yields earned=true', () async {
      RewardResult? result;
      final ad = await loadAndShow((r) => result = r);
      bridge.rewarded!.onAdReceivedRewardCallback(ad, MaxReward(10, 'c'));
      expect(result, isNotNull);
      expect(result!.earned, isTrue);
    });

    test('hiding without a reward yields skipped (not earned)', () async {
      RewardResult? result;
      final ad = await loadAndShow((r) => result = r);
      bridge.rewarded!.onAdHiddenCallback(ad);
      expect(result, isNotNull);
      expect(result!.earned, isFalse);
    });

    // Round-23 audit, MAJOR — `shown` is what AdManager charges the
    // daily/hourly/placement caps on, so it has to follow the DISPLAY.
    test('displayed then closed early → shown=true, earned=false', () async {
      RewardResult? result;
      final ad = await loadAndShow((r) => result = r);
      bridge.rewarded!.onAdDisplayedCallback(ad);
      bridge.rewarded!.onAdHiddenCallback(ad);

      expect(result!.earned, isFalse);
      expect(result!.shown, isTrue,
          reason: 'the user saw an ad — it must consume cap budget');
    });

    test('hidden without ever being displayed → shown=false', () async {
      RewardResult? result;
      final ad = await loadAndShow((r) => result = r);
      bridge.rewarded!.onAdHiddenCallback(ad);

      expect(result!.shown, isFalse);
    });

    test('an earned reward always reports shown=true', () async {
      RewardResult? result;
      final ad = await loadAndShow((r) => result = r);
      bridge.rewarded!.onAdDisplayedCallback(ad);
      bridge.rewarded!.onAdReceivedRewardCallback(ad, MaxReward(10, 'c'));

      expect(result!.shown, isTrue);
    });

    // Round-23 audit, MAJOR (independent review) — the reward path reports
    // `shown: true` as a CONSTANT rather than reading
    // `rewardedSlot.displayConfirmed`, and that is deliberate: a reward can
    // only be granted by an ad that was on screen, so the reward itself is a
    // stronger display proof than the display callback. Reading
    // `displayConfirmed` here instead would UNDERCOUNT the impression on
    // exactly the reordering below — a reward delivered while the display
    // callback was lost or late — which is the failure this whole round was
    // fixing. Locked down here so nobody "unifies" it later.
    test('a reward that arrives with no display callback still reports '
        'shown=true', () async {
      RewardResult? result;
      final ad = await loadAndShow((r) => result = r);
      // No onAdDisplayedCallback at all.
      bridge.rewarded!.onAdReceivedRewardCallback(ad, MaxReward(10, 'c'));

      expect(adapter.rewardedSlot.displayConfirmed, isFalse,
          reason: 'precondition: the display callback never arrived');
      expect(result!.earned, isTrue);
      expect(result!.shown, isTrue,
          reason: 'a reward proves the ad was on screen');
    });
  });

  group('Interstitial reload-after-display-fail', () {
    test('display failure refills immediately', () async {
      final ad = _fakeAd();
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(ad);
      expect(adapter.interstitialSlot.isReady, isTrue);

      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdDisplayFailedCallback(ad, _fakeError());

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
  // Round-7 audit, MAJOR — the widget-format twin of the group below. AdMob's
  // banner/mrec/native paths have armed a load watchdog since MJ20; AppLovin's
  // two armed none, even though preloadBanner's own M3 comment claimed
  // "and with it the load watchdog that state enables". Once `beginLoad()`
  // succeeds the slot waits on the widget listener's callbacks; if neither
  // arrives the slot stays `loading` for the session, every later preload —
  // the resume recovery's included — bounces off the `beginLoad()` guard, and
  // the widget keeps its shimmer forever.
  group('Widget-format load watchdog (AppLovin banner/MREC)', () {
    test('banner: a listener callback that never arrives is recovered', () {
      fakeAsync((async) {
        adapter.preloadBanner('k');
        async.flushMicrotasks();
        expect(adapter.bannerSlot('k').isLoading, isTrue,
            reason: 'sanity: the request went out and the slot is waiting');

        async.elapse(const Duration(seconds: 29));
        expect(adapter.bannerSlot('k').isLoading, isTrue,
            reason: 'must not fire before its 30s deadline — a mediated '
                'waterfall can legitimately take many seconds');

        async.elapse(const Duration(seconds: 2));
        expect(adapter.bannerSlot('k').isLoading, isFalse);
        expect(adapter.banner('k').needsRecovery, isTrue,
            reason: 'THE POINT: without a failure flag the resume recovery has '
                'no re-entry condition, so nothing ever retries this key');
        expect(adapter.banner('k').isLoaded.value, isFalse);
      });
    });

    test('banner: a load that lands in time disarms it', () {
      fakeAsync((async) {
        adapter.preloadBanner('k');
        async.flushMicrotasks();
        final id = adapter.appLovinBannerAdViewId('k').value as AdViewId?;
        bridge.widget!.onAdLoadedCallback(MaxAd('banner-id', 'BANNER', id,
            'net', '', 0.0, 'exact', 'cid', 'dsp', '', 0,
            MaxAdWaterfallInfo('', '', const [], 0), null, null));

        async.elapse(const Duration(minutes: 5));
        expect(adapter.banner('k').needsRecovery, isFalse);
        expect(adapter.banner('k').hasError.value, isFalse);
      });
    });

    test('MREC: a listener callback that never arrives is recovered', () {
      fakeAsync((async) {
        // Local adapter: the shared `_config` declares no mrecId, so the
        // shared adapter always no-ops preloadMrec.
        final a = AppLovinAdapter(bridge: FakeAppLovinBridge());
        a.initialize(const AdConfig(
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
        async.flushMicrotasks();
        addTearDown(a.dispose);

        a.preloadMrec('k');
        async.flushMicrotasks();
        expect(a.mrecSlot('k').isLoading, isTrue);

        async.elapse(const Duration(seconds: 31));
        expect(a.mrecSlot('k').isLoading, isFalse);
        expect(a.mrec('k').needsRecovery, isTrue);
      });
    });
  });

  group('Widget instance disposed while its preload is in flight', () {
    Future<AppLovinAdapter> adapterWith(_DeferredPreloadBridge b) async {
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
      return a;
    }

    test('banner: the late adViewId is destroyed, not parked in a zombie slot',
        () async {
      final b = _DeferredPreloadBridge();
      final a = await adapterWith(b);

      final pending = a.preloadBanner('k');
      expect(a.bannerSlot('k').isLoading, isTrue);

      // The BannerAdWidget unmounts (route pop / VIP grant) mid-flight.
      a.disposeBannerInstance('k');
      b.gate.complete(7);
      await pending;

      expect(b.destroyWidgetAdViewCalls, contains(7),
          reason: 'the native AdView we were handed must be released');
      expect(a.bannerSlots, isEmpty,
          reason: 'a resurrected slot would keep the reload sweeps requesting '
              'ads for a widget that no longer exists');
    });

    test('MREC: the late adViewId is destroyed, not parked in a zombie slot',
        () async {
      final b = _DeferredPreloadBridge();
      final a = await adapterWith(b);

      final pending = a.preloadMrec('k');
      expect(a.mrecSlot('k').isLoading, isTrue);

      a.disposeMrecInstance('k');
      b.gate.complete(9);
      await pending;

      expect(b.destroyWidgetAdViewCalls, contains(9));
      expect(a.mrecSlots, isEmpty);
    });

    test('banner: a null adViewId after dispose resurrects nothing', () async {
      final b = _DeferredPreloadBridge();
      final a = await adapterWith(b);

      final pending = a.preloadBanner('k');
      a.disposeBannerInstance('k');
      b.gate.complete(null);
      await pending;

      expect(a.bannerSlots, isEmpty);
    });
  });

  group('Load watchdog on adapter-internal reload (no AdManager in the loop)',
      () {
    test('appOpen: reload-after-display-fail recovers via watchdog if the '
        'native callback never arrives', () {
      fakeAsync((async) {
        final ad = _fakeAd();
        adapter.loadAppOpen();
        async.flushMicrotasks();
        bridge.appOpen!.onAdLoadedCallback(ad);
        adapter.showAppOpen(onDismiss: (_) {});
        async.flushMicrotasks();

        // Triggers the internal reload — bridge.loadAppOpenAd is called
        // again, but we deliberately never fire another callback for it.
        bridge.appOpen!.onAdDisplayFailedCallback(ad, _fakeError());
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
        final ad = _fakeAd();
        adapter.loadInterstitial();
        async.flushMicrotasks();
        bridge.inter!.onAdLoadedCallback(ad);
        adapter.showInterstitial(onDone: (_) {});
        async.flushMicrotasks();

        bridge.inter!.onAdDisplayFailedCallback(ad, _fakeError());
        expect(adapter.interstitialSlot.isLoading, isTrue);

        async.elapse(const Duration(seconds: 31));
        expect(adapter.interstitialSlot.isLoading, isFalse,
            reason: 'watchdog must force the slot out of loading');
      });
    });

    test('rewarded: reload-after-display-fail recovers via watchdog if the '
        'native callback never arrives', () {
      fakeAsync((async) {
        final ad = _fakeAd();
        adapter.loadRewarded();
        async.flushMicrotasks();
        bridge.rewarded!.onAdLoadedCallback(ad);
        adapter.showRewarded(onDone: (_) {});
        async.flushMicrotasks();

        bridge.rewarded!.onAdDisplayFailedCallback(ad, _fakeError());
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
      final ad = _fakeAd();
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(ad);
      await adapter.showInterstitial(onDone: (_) {});
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdHiddenCallback(ad);

      expect(bridge.loadInterCalls.length, loadsBefore);
    });

    test(
        'interstitial: display failure does not reload when canReload is false',
        () async {
      adapter.canReload = () => false;
      final ad = _fakeAd();
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(ad);
      await adapter.showInterstitial(onDone: (_) {});
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdDisplayFailedCallback(ad, _fakeError());

      expect(bridge.loadInterCalls.length, loadsBefore);
    });

    test('rewarded: hidden does not reload when canReload is false', () async {
      adapter.canReload = () => false;
      final ad = _fakeAd();
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(ad);
      await adapter.showRewarded(onDone: (_) {});
      final loadsBefore = bridge.loadRewardedCalls.length;

      bridge.rewarded!.onAdHiddenCallback(ad);

      expect(bridge.loadRewardedCalls.length, loadsBefore);
    });

    test('rewarded: display failure does not reload when canReload is false',
        () async {
      adapter.canReload = () => false;
      final ad = _fakeAd();
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(ad);
      await adapter.showRewarded(onDone: (_) {});
      final loadsBefore = bridge.loadRewardedCalls.length;

      bridge.rewarded!.onAdDisplayFailedCallback(ad, _fakeError());

      expect(bridge.loadRewardedCalls.length, loadsBefore);
    });

    test('interstitial: reloads normally when canReload stays true (default)',
        () async {
      final ad = _fakeAd();
      await adapter.loadInterstitial();
      bridge.inter!.onAdLoadedCallback(ad);
      await adapter.showInterstitial(onDone: (_) {});
      final loadsBefore = bridge.loadInterCalls.length;

      bridge.inter!.onAdHiddenCallback(ad);

      expect(bridge.loadInterCalls.length, loadsBefore + 1);
    });
  });

  group('round-38 audit (own finding, hedge): dispose() while genuinely '
      'showing', () {
    final captured = <String>[];

    setUp(() {
      captured.clear();
      SafeLogger.configure(
        level: AdLogLevel.warning,
        onLog: (level, tag, message) => captured.add(message),
      );
    });

    tearDown(() => SafeLogger.resetForTest());

    test(
        'a whole-adapter dispose() while rewarded is genuinely showing '
        'still resolves the pending callback (no hang) and logs a warning '
        'instead of silently pretending it was an ordinary teardown',
        () async {
      // Own local instance — NOT the shared `adapter`/`bridge` from the
      // outer setUp, so this test's own explicit dispose() (needed to
      // capture the warning inside this group's log window) doesn't race
      // the outer file-level tearDown's unconditional `adapter.dispose()`
      // on that shared instance (AppLovinAdapter.dispose() isn't
      // idempotent — a real, pre-existing constraint, not something this
      // fix introduced).
      final localBridge = FakeAppLovinBridge();
      final localAdapter = AppLovinAdapter(bridge: localBridge);
      expect(await localAdapter.initialize(_config), isTrue);

      final ad = _fakeAd();
      await localAdapter.loadRewarded();
      localBridge.rewarded!.onAdLoadedCallback(ad);
      expect(localAdapter.rewardedSlot.isReady, isTrue);

      RewardResult? result;
      await localAdapter.showRewarded(onDone: (r) => result = r);
      localBridge.rewarded!.onAdDisplayedCallback(ad);
      expect(localAdapter.rewardedSlot.isShowing, isTrue,
          reason: 'precondition: no hidden/dismiss callback has fired yet');

      await localAdapter.dispose();

      expect(result, isNotNull,
          reason: 'the pending caller must not hang forever');
      expect(result!.shown, isFalse);
      expect(
          captured.any((m) =>
              m.contains('genuinely showing') && m.contains('rewarded')),
          isTrue,
          reason: 'this rare edge case must be diagnosable in logs, since '
              'AppLovin MAX has no API to actually dismiss the native view');
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
    // Round-31 audit follow-up — [ad] threaded through explicitly (instead
    // of the helper minting its own `_fakeAd()`) so callers that need to
    // fire a display/hidden callback afterward pass the SAME instance the
    // adapter actually loaded. The fix added ad-identity tracking to App
    // Open too, so a fresh `_fakeAd()` per callback call is now (correctly)
    // discarded as stale — see AppLovinAdapter._appOpenAd.
    AppLovinAdapter armedViaRealShow(
      FakeAppLovinBridge b,
      AppLifecycleState lifecycle,
      FakeAsync async,
      void Function(bool) onDismiss, {
      required MaxAd ad,
    }) {
      final a = AppLovinAdapter(
        bridge: b,
        lifecycleStateResolver: () => lifecycle,
      );
      a.initialize(_config);
      async.flushMicrotasks();
      a.loadAppOpen();
      b.appOpen!.onAdLoadedCallback(ad);
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
        }, ad: _fakeAd());

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

    // Round-23 audit, MAJOR — see AppLovinAdapter._resolveAppOpenAfterLostCallback.
    test('Android: a CONFIRMED display resolves as dismissed(true) on timeout',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeAsync((async) {
        final b = FakeAppLovinBridge();
        bool? dismissed;
        final ad = _fakeAd();
        final a = armedViaRealShow(
            b, AppLifecycleState.resumed, async, (d) => dismissed = d,
            ad: ad);
        b.appOpen!.onAdDisplayedCallback(ad); // really on screen

        async.elapse(const Duration(seconds: 20));

        expect(dismissed, isTrue,
            reason: 'the ad was displayed; only its hidden callback was lost');
        expect(a.appOpenSlot.value, AdSlotState.idle,
            reason: 'a lost callback is not a show failure — no backoff');
      });
      debugDefaultTargetPlatformOverride = null;
    });

    test('iOS: the 90s hard cap on a CONFIRMED display reports dismissed(true)',
        () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fakeAsync((async) {
        final b = FakeAppLovinBridge();
        bool? dismissed;
        final ad = _fakeAd();
        final a = armedViaRealShow(
            b, AppLifecycleState.resumed, async, (d) => dismissed = d,
            ad: ad);
        b.appOpen!.onAdDisplayedCallback(ad);

        async.elapse(const Duration(seconds: 100));

        expect(dismissed, isTrue);
        expect(a.appOpenSlot.value, AdSlotState.idle);
      });
      debugDefaultTargetPlatformOverride = null;
    });

    test('native hide cancels the armed watchdog (no late double-dismiss)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeAsync((async) {
        final b = FakeAppLovinBridge();
        var calls = 0;
        bool? dismissed;
        final ad = _fakeAd();
        armedViaRealShow(b, AppLifecycleState.resumed, async, (d) {
          calls++;
          dismissed = d;
        }, ad: ad);

        // AppLovin's native onAdHidden resolves the show.
        b.appOpen!.onAdHiddenCallback(ad);
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

    // m24 (audit_claude.md MINOR) — dispose()'s key loop only walked the SLOT
    // maps, but banner(key)/mrec(key)/native(key) and
    // appLovinBannerAdViewId(key) each create their own per-key entry
    // independently. A key that was only ever asked for those (the notifiers
    // must be resolved BEFORE dispose — afterwards every getter hands back the
    // shared pre-disposed singleton, which hides the leak) had its
    // ValueNotifiers left alive for good.
    test('m24 — per-key notifiers created without a slot are disposed too',
        () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);

      final banner = a.banner('lonely-banner');
      final mrec = a.mrec('lonely-mrec');
      final native = a.native('lonely-native');
      final bannerAdViewId = a.appLovinBannerAdViewId('lonely-banner-id');
      final mrecAdViewId = a.appLovinMrecAdViewId('lonely-mrec-id');

      await a.dispose();

      expect(() => banner.isLoaded.addListener(() {}), throwsFlutterError,
          reason: 'banner listenables with no slot must still be disposed');
      expect(() => mrec.isLoaded.addListener(() {}), throwsFlutterError,
          reason: 'mrec listenables with no slot must still be disposed');
      expect(() => native.isLoaded.addListener(() {}), throwsFlutterError,
          reason: 'native listenables with no slot must still be disposed');
      expect(() => bannerAdViewId.addListener(() {}), throwsFlutterError,
          reason: 'banner adViewId with no slot must still be disposed');
      expect(() => mrecAdViewId.addListener(() {}), throwsFlutterError,
          reason: 'mrec adViewId with no slot must still be disposed');
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

      // No per-key allocation happened either: every dead key shares the one
      // disposed sentinel, so nothing accumulated in the maps.
      final otherDead = Object();
      a.native(otherDead).isLoaded.value = true; // materialize, then kill it
      a.disposeNativeInstance(otherDead);
      expect(identical(a.native(key), a.native(otherDead)), isTrue,
          reason: 'two dead keys must resolve to the SAME disposed sentinel, '
              'proving no map entry was created for either');
    });

    // Regression (2026-08-22): the tombstone above must not outlive the
    // widget. The key is the NativeAdWidget's State object and it IS reused —
    // _onPersonalisationWithdrawn() disposes the instance and then re-inits
    // the SAME `this`, and the consent-gate close/reopen path does the same.
    // With a permanent tombstone the native ad never came back for that
    // widget and its callbacks wrote to disposed ValueNotifiers. Driven
    // through AdManager because that is the exact pair of calls the widget
    // makes: disposeNativeInstance(this), then recordNativeLoad(this) from
    // _initNative().
    test('a disposed key re-loaded by the same live widget gets a USABLE '
        'slot/listenables back (recordNativeLoad lifts the tombstone)',
        () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);
      final mgr = AdManager();
      mgr.debugSetAdapter(a);
      addTearDown(() => mgr.debugSetAdapter(null));

      final key = Object();
      a.native(key).isLoaded.value = true;
      mgr.disposeNativeInstance(key); // widget drops the live instance

      mgr.recordNativeLoad(key); // ...and re-inits the SAME State object

      final revived = a.native(key);
      expect(() => revived.isLoaded.value = true, returnsNormally,
          reason: 'a re-inited widget must get live listenables, not the '
              'permanently-disposed sentinel');
      expect(revived.isLoaded.value, isTrue);
      expect(a.nativeSlot(key).beginLoad(), isTrue,
          reason: 'its AdSlot must be usable again too');
    });

    // T104 — the tombstone Set above (`_disposedNativeKeys`) protects against
    // a late callback resurrecting a dead key, but it used to never shrink:
    // a screen that scrolls many native ads through a long-lived ListView
    // (T73's exact use case) added one entry per ad that scrolled away and
    // was never revived, forever — an unbounded leak over a long session.
    test('disposing far more native keys than the cap does not grow the '
        'tombstone set without bound', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);

      for (var i = 0; i < 500; i++) {
        final key = Object();
        a.native(key); // materializes a live entry
        a.disposeNativeInstance(key);
      }

      expect(a.debugDisposedNativeKeysCount, lessThanOrEqualTo(200),
          reason: 'disposing 500 distinct keys must not leave 500 tombstones '
              'sitting in memory forever — the set must be bounded');
    });

    // Round-33 audit (R33-03) — native_ad_widget.dart's onAdRevenuePaidCallback
    // writes straight into the shared AdSafetyConfig counter and event sink,
    // unlike onAdLoaded/onAdFailedToLoad which write into a per-key notifier
    // that throws (and gets caught) once disposed. [isNativeInstanceDisposed]
    // is the public check that callback needs to drop a late revenue event
    // for an already-disposed instanceKey instead of silently recording it.
    test('isNativeInstanceDisposed reflects the tombstone set', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      await a.initialize(_config);
      addTearDown(a.dispose);

      final key = Object();
      expect(a.isNativeInstanceDisposed(key), isFalse,
          reason: 'a key never touched is not disposed');

      a.native(key); // materializes a live entry
      expect(a.isNativeInstanceDisposed(key), isFalse);

      a.disposeNativeInstance(key);
      expect(a.isNativeInstanceDisposed(key), isTrue);
    });
  });

  group('onAppResumed() recreates errored banner AdView (T34)', () {
    // M3 (round-6 audit) — the two tests below, and the recovery path they
    // cover, all begin by setting `hasError` BY HAND. Nothing proved the flag
    // ever becomes true from a real no-fill, and it did not: the adapter's
    // `onAdLoadFailedCallback` walks `_bannerSlotsByKey` / `_mrecSlotsByKey`
    // and only acts `if (slot.isLoading)`, but the preload path never put the
    // slot into `loading` — so on AppLovin a banner or MREC that got no fill
    // sat in the widget's shimmer for the rest of the session, never retried
    // (the resume recovery keys off the failure flags), and emitted no event,
    // leaving fill-rate monitoring blind to every AppLovin banner failure.
    test('a real no-fill marks the banner errored (not just a hand-set flag)',
        () async {
      await adapter.preloadBanner('k');
      final adViewId = adapter.appLovinBannerAdViewId('k').value;
      expect(adViewId, isNotNull, reason: 'sanity: fake bridge preloads an id');
      expect(adapter.banner('k').hasError.value, isFalse,
          reason: 'sanity: not errored before the callback');

      // The bridge reports the AD-UNIT id on failure, not the adViewId (see
      // onAdLoadFailedCallback). Passing the adViewId made this pass for the
      // wrong reason: it fell through to the banner branch by default.
      bridge.widget!.onAdLoadFailedCallback('banner-id', _fakeError());

      expect(adapter.banner('k').hasError.value, isTrue,
          reason: 'the widget layer collapses the shimmer on hasError, and '
              'markError() is what arms needsRecovery — without this the banner '
              'is stuck in fake-ad shimmer for the whole session');
      expect(adapter.bannerSlot('k').value, AdSlotState.cooldown,
          reason: 'a no-fill is a load failure and must feed the backoff');
    });

    // Round-6 codex QC — the M3 fix called beginLoad() but threw the answer
    // away, so a retry while the slot was still inside its backoff window sent
    // the request anyway with the slot NOT in `loading`, and the no-fill was
    // swallowed exactly as before. The first two tests only covered a first
    // load from idle, which is why they missed it. AdMob's banner path has
    // always honoured the return value (admob_adapter.dart:1548) with the same
    // rationale: a flapping banner is cheap to skip.
    test('a retry inside the backoff window is skipped, not sent unlatched',
        () async {
      final b = _CountingPreloadBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      addTearDown(a.dispose);

      await a.preloadBanner('k');
      expect(b.preloadCalls, 1, reason: 'sanity: first load was sent');
      b.widget!.onAdLoadFailedCallback('banner-id', _fakeError());
      expect(a.bannerSlot('k').value, AdSlotState.cooldown,
          reason: 'sanity: the no-fill put the slot in cooldown');

      await a.preloadBanner('k'); // immediate retry, still inside the backoff

      expect(b.preloadCalls, 1,
          reason: 'beginLoad() refused (cooldown + backoff), so no request may '
              'go out. Sending it anyway leaves the slot NOT in `loading`, '
              'which is exactly the state that made the no-fill handler dead '
              'code in the first place');
    });

    // Round-6 final QC, found independently by BOTH reviewers, then reproduced
    // once more after the first attempt at fixing it:
    //
    // `hasError` used to mean two things at once — "paint nothing" AND "this
    // key still owes a retry". onAppResumed cleared it BEFORE it knew the
    // re-request had been accepted, so a refusal (slot still inside its failure
    // backoff) left the widget with no error flag, no ad, and no surviving
    // reason for anything to try again: a permanently blank banner for the rest
    // of the session.
    //
    // The first fix let recovery skip the backoff instead. That traded the
    // blank banner for unlimited requests from a flapping app, and rate-limiting
    // the bypass brought the blank banner straight back (a refused bypass is
    // still a refusal). So the flags are split: `hasError` is display-only, and
    // `needsRecovery` is cleared only by an actual success. Recovery may then
    // clear the display flag freely, and honour the backoff, because the claim
    // itself survives to the next resume.
    test('a recovery attempt refused by the backoff is retried on the next '
        'resume, not abandoned', () async {
      final b = _CountingPreloadBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      addTearDown(a.dispose);

      await a.preloadBanner('k');
      expect(b.preloadCalls, 1, reason: 'sanity: first load was sent');
      b.widget!.onAdLoadFailedCallback('banner-id', _fakeError());
      expect(a.bannerSlot('k').value, AdSlotState.cooldown,
          reason: 'sanity: the no-fill put the slot in its backoff');
      expect(a.banner('k').needsRecovery, isTrue,
          reason: 'a failed load is what creates the retry claim');

      a.onAppResumed();
      await Future<void>.value();
      await Future<void>.value();

      expect(b.preloadCalls, 1,
          reason: 'the backoff is honoured — recovery gets no free request');
      expect(a.banner('k').hasError.value, isFalse,
          reason: 'display flag cleared, so the widget shows its shimmer '
              'rather than collapsing to nothing');
      expect(a.banner('k').needsRecovery, isTrue,
          reason: 'THE FIX: the refused attempt must leave the claim standing. '
              'When this collapsed into `hasError` the recovery branch erased '
              'its own re-entry condition and the banner stayed blank forever');

      // The backoff window elapses (15s base for a single failure).
      a.bannerSlot('k').lastErrorAt =
          DateTime.now().subtract(const Duration(seconds: 20));

      a.onAppResumed();
      await Future<void>.value();
      await Future<void>.value();

      expect(b.preloadCalls, 2,
          reason: 'the next resume finds the claim still set and retries');
    });

    test('a successful load settles the recovery claim', () async {
      final b = _CountingPreloadBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      addTearDown(a.dispose);

      await a.preloadBanner('k');
      b.widget!.onAdLoadFailedCallback('banner-id', _fakeError());
      expect(a.banner('k').needsRecovery, isTrue);

      // The loaded callback is dispatched by matching adViewId against the
      // key's notifier — the shared _fakeAd() carries none, so it would be
      // dropped as a stale callback and prove nothing.
      b.widget!.onAdLoadedCallback(MaxAd('banner-id', 'BANNER',
          a.appLovinBannerAdViewId('k').value as AdViewId?, 'net', '', 0.0,
          'exact', 'cid',
          'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0), null, null));

      expect(a.banner('k').needsRecovery, isFalse,
          reason: 'otherwise every later resume would tear down a working '
              'banner and re-request it');

      a.onAppResumed();
      await Future<void>.value();
      await Future<void>.value();
      expect(b.preloadCalls, 1, reason: 'nothing left to recover');
    });

    test('MREC: a recovery attempt refused by the backoff is retried on the '
        'next resume', () async {
      final b = _CountingPreloadBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(
        await a.initialize(const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'sdk',
            bannerId: 'banner-id',
            mrecId: 'mrec-id',
            interstitialId: 'inter-id',
            appOpenId: 'appopen-id',
            rewardedId: 'rewarded-id',
          ),
        )),
        isTrue,
      );
      addTearDown(a.dispose);

      await a.preloadMrec('k');
      expect(b.preloadCalls, 1);
      b.widget!.onAdLoadFailedCallback('mrec-id', _fakeError());
      expect(a.mrec('k').needsRecovery, isTrue);

      a.onAppResumed();
      await Future<void>.value();
      await Future<void>.value();
      expect(b.preloadCalls, 1, reason: 'backoff honoured');
      expect(a.mrec('k').hasError.value, isFalse);
      expect(a.mrec('k').needsRecovery, isTrue);

      a.mrecSlot('k').lastErrorAt =
          DateTime.now().subtract(const Duration(seconds: 20));
      a.onAppResumed();
      await Future<void>.value();
      await Future<void>.value();
      expect(b.preloadCalls, 2);
    });

    test('a real no-fill marks the MREC errored too', () async {
      // The shared _config declares no mrecId, so preloadMrec would return
      // early there — this needs its own adapter.
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(
        await a.initialize(const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'sdk',
            bannerId: 'banner-id',
            mrecId: 'mrec-id',
            interstitialId: 'inter-id',
            appOpenId: 'appopen-id',
            rewardedId: 'rewarded-id',
          ),
        )),
        isTrue,
      );
      addTearDown(a.dispose);

      await a.preloadMrec('k');
      expect(a.appLovinMrecAdViewId('k').value, isNotNull,
          reason: 'sanity: fake bridge preloads an id');

      b.widget!.onAdLoadFailedCallback('mrec-id', _fakeError());

      expect(a.mrec('k').hasError.value, isTrue);
      expect(a.mrecSlot('k').value, AdSlotState.cooldown);
    });

    test('destroys the stale native AdView before preloading a replacement',
        () async {
      await adapter.preloadBanner('k');
      final oldId = adapter.appLovinBannerAdViewId('k').value;
      expect(oldId, isNotNull, reason: 'fake bridge preloads id=1');

      adapter.banner('k').markError();
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

      adapter.banner('a').markError();
      adapter.banner('b').markError();
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

      // Round-6 QC — a re-preload while the first load is still in flight is
      // now correctly refused (beginLoad() returns false for isLoading), so
      // complete it first. This is scene-setting, not the assertion: the
      // destroy-instead-of-leak behaviour below still runs through the real
      // path. In production this sequence arrives via onAppResumed recovery,
      // where the previous load has already FAILED, so the slot is in cooldown
      // rather than loading.
      a.bannerSlot('k').markReady();

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

      // Round-6 QC — a re-preload while the first load is still in flight is
      // now correctly refused (beginLoad() returns false for isLoading), so
      // complete it first. This is scene-setting, not the assertion: the
      // destroy-instead-of-leak behaviour below still runs through the real
      // path. In production this sequence arrives via onAppResumed recovery,
      // where the previous load has already FAILED, so the slot is in cooldown
      // rather than loading.
      a.mrecSlot('k').markReady();

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

    // m22 (audit_claude.md MINOR) — the retry chain that makes the fix above
    // survive "native refused, AdView still attached" used a bare
    // Future.delayed, so it kept re-entering the bridge for ~1.7s after the
    // adapter was torn down.
    test('m22 — dispose() cancels the pending destroyWidgetAdView retry', () {
      fakeAsync((async) {
        final b = _FailingDestroyBridge();
        final a = AppLovinAdapter(bridge: b);
        a.initialize(_config);
        async.flushMicrotasks();

        a.preloadBanner('k');
        async.flushMicrotasks();
        final id = a.appLovinBannerAdViewId('k').value;
        expect(id, isNotNull);

        a.disposeBannerInstance('k');
        async.flushMicrotasks();
        expect(b.destroyWidgetAdViewCalls, [id],
            reason: 'first attempt runs synchronously-ish and is rejected');

        a.dispose();
        async.flushMicrotasks();
        // Past every entry of _destroyRetryDelays (200ms + 500ms + 1s).
        async.elapse(const Duration(seconds: 3));

        expect(b.destroyWidgetAdViewCalls, [id],
            reason: 'no retry may reach the bridge after dispose() — its '
                'native listeners are already cleared and the AdView id '
                'belongs to nobody');
      });
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
  group('round-16 teardown race — a preload landing inside dispose()', () {
    test(
        'a banner AdView delivered while dispose() is destroying another one '
        'is destroyed too, and the teardown still runs to the end', () async {
      final b = _TeardownRaceBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);

      // 1. key "hold" owns native AdView id 1.
      await a.preloadBanner('hold');
      expect(a.banner('hold'), isNotNull);

      // 2. key "race" starts a preload that has not come back yet.
      b.deferNextPreload = true;
      final racing = a.preloadBanner('race');

      // 3. dispose() begins and parks inside destroyWidgetAdView(1).
      bool? appOpenAnswer;
      await a.loadAppOpen(onAdLoaded: (ok) => appOpenAnswer = ok);
      final disposing = a.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(b.destroyWidgetAdViewCalls, contains(1),
          reason: 'control — the teardown really is parked in the destroy '
              'await, which is the window under test');

      // 4. the racing preload comes back with a brand-new AdView id.
      b.racePreload.complete(2);
      await Future<void>.delayed(Duration.zero);

      // 5. let both destroys through and finish the teardown.
      b.destroyGate.complete();
      await racing;
      await disposing;

      expect(b.destroyWidgetAdViewCalls, contains(2),
          reason: 'the AdView delivered after the teardown began belongs to '
              'nobody — if it is not destroyed here it is leaked native-side '
              'for the rest of the process');
      expect(appOpenAnswer, isFalse,
          reason: 'proves dispose() ran PAST the AdView loops: before the fix '
              'a ConcurrentModificationError aborted it right there, leaving '
              'this callback unanswered forever');
    });

    test('the same race on MREC', () async {
      final b = _TeardownRaceBridge();
      final a = AppLovinAdapter(bridge: b);
      // The shared `_config` configures no mrecId, and `preloadMrec` correctly
      // refuses to request one without it.
      expect(
          await a.initialize(const AdConfig(
              provider: AdProvider.appLovin,
              appLovin: AppLovinConfig(
                  sdkKey: 'sdk',
                  bannerId: 'banner-id',
                  mrecId: 'mrec-id',
                  interstitialId: 'inter-id',
                  appOpenId: 'appopen-id',
                  rewardedId: 'rewarded-id'))),
          isTrue);

      await a.preloadMrec('hold');
      b.deferNextPreload = true;
      final racing = a.preloadMrec('race');

      bool? appOpenAnswer;
      await a.loadAppOpen(onAdLoaded: (ok) => appOpenAnswer = ok);
      final disposing = a.dispose();
      await Future<void>.delayed(Duration.zero);
      b.racePreload.complete(2);
      await Future<void>.delayed(Duration.zero);
      b.destroyGate.complete();
      await racing;
      await disposing;

      expect(b.destroyWidgetAdViewCalls, contains(2));
      expect(appOpenAnswer, isFalse);
    });

    test(
        'a destroy that fails AFTER the teardown does not arm a retry timer '
        'that outlives the adapter', () async {
      final b = _DeferredFailingDestroyBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);

      await a.preloadBanner('k');
      // Starts the destroy chain and leaves it parked in the native await.
      a.disposeBannerInstance('k');
      await Future<void>.delayed(Duration.zero);
      expect(b.destroyWidgetAdViewCalls, [1],
          reason: 'control — the first destroy is in flight');

      await a.dispose();
      // Now let the in-flight destroy fail, the way the native side does while
      // the platform view is still attached.
      b.firstDestroy.complete();
      // Longer than the first retry delay, so an armed timer would have fired.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(b.destroyWidgetAdViewCalls, [1],
          reason: 'a retry armed after dispose() talks to a bridge whose '
              'listeners are already cleared, and its timer is never '
              'cancellable — teardown means stop');
    });

    test(
        'CONTROL — the same failure BEFORE any teardown still retries, so the '
        'guard did not disable the retry chain', () async {
      final b = _DeferredFailingDestroyBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);

      await a.preloadBanner('k');
      a.disposeBannerInstance('k');
      await Future<void>.delayed(Duration.zero);
      b.firstDestroy.complete();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(b.destroyWidgetAdViewCalls.length, greaterThan(1),
          reason: 'the retry chain is what stops a detached AdView leaking on '
              'a live adapter — it must still work');
      await a.dispose();
    });

    test(
        'CONTROL — with no teardown in flight a preload keeps its AdView and '
        'nothing is destroyed', () async {
      final b = _TeardownRaceBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      addTearDown(() {
        b.destroyGate.complete();
        return a.dispose();
      });

      await a.preloadBanner('live');
      expect(b.destroyWidgetAdViewCalls, isEmpty,
          reason: 'a healthy preload must not destroy what it just created');
    });
  });

  // T105 — nulling the bridge listeners in dispose() only stops FUTURE
  // native calls; one already sitting in the Dart event queue at that moment
  // still runs on its old closure and still reaches `_emit`, which reads
  // `eventSink` at call time. Nulling `eventSink` itself turns that
  // straggler into a no-op instead of a click/open counting against a
  // placement that no longer exists.
  test('dispose() nulls eventSink so a straggler callback cannot emit '
      'through it', () async {
    final b = FakeAppLovinBridge();
    final a = AppLovinAdapter(bridge: b);
    expect(await a.initialize(_config), isTrue);
    a.eventSink = (_) {};

    await a.dispose();

    expect(a.eventSink, isNull);
  });

  // Round-29 audit (BLOCKER) — the T105 test above only proves `_emit`
  // becomes a no-op after dispose(); it never checked whether the *slot
  // mutation* right before `_emit` (`appOpenSlot.markReady()` etc.) was also
  // guarded. It wasn't — AdMob got a `_fullscreenDisposed` check in every
  // fullscreen `onLoaded`/`onFailed` callback in round 27; AppLovin never
  // did, despite already having `_teardownStarted` set at the very top of
  // dispose() for exactly this purpose (see `_destroyWidgetAdViewWhenDetached`
  // reading it a few hundred lines up).
  group('round-29 audit (BLOCKER): late fullscreen load callback after '
      'dispose() must not mutate the slot', () {
    // Note: `AdSlot.state` (a `ValueNotifier`) already silently drops writes
    // after `AdSlot.dispose()` — so `isReady`/`.value` are NOT a reliable
    // oracle here (already masked, pre- and post-fix alike). `lastLoadedAt`/
    // `lastErrorAt`/`consecutiveFailures` are plain fields `markReady()`/
    // `markFailed()` write unconditionally, unprotected by that — a real,
    // reliable pre-fix-vs-post-fix difference.
    test('appOpen onAdLoadedCallback', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      await a.loadAppOpen();
      final stale = b.appOpen!;

      await a.dispose();
      stale.onAdLoadedCallback(_fakeAd());

      expect(a.appOpenSlot.lastLoadedAt, isNull,
          reason: 'a load that lands after dispose() must not mark a slot '
              'on an adapter nobody owns any more as loaded');
    });

    test('interstitial onAdLoadFailedCallback', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      await a.loadInterstitial();
      final stale = b.inter!;

      await a.dispose();
      stale.onAdLoadFailedCallback('inter-id', _fakeError());

      expect(a.interstitialSlot.lastErrorAt, isNull,
          reason: 'a failure that lands after dispose() must not touch a '
              'slot on an adapter nobody owns any more');
    });

    test('rewarded onAdLoadedCallback', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      await a.loadRewarded();
      final stale = b.rewarded!;

      await a.dispose();
      stale.onAdLoadedCallback(_fakeAd());

      expect(a.rewardedSlot.lastLoadedAt, isNull,
          reason: 'a load that lands after dispose() must not mark a slot '
              'on an adapter nobody owns any more as loaded');
    });

    // Round-31 audit — an explicit `_teardownStarted` check on the shared
    // banner/mrec widget listener (matching round-29's B3 guard on App
    // Open/Interstitial/Rewarded) was tried and reverted: it turned out
    // unnecessary. `dispose()` sets `_bannerDisposed`/`_mrecDisposed` in
    // the same synchronous block as `_teardownStarted`, and every mutation
    // this callback makes goes through `_bannerSlotFor`/`_mrecSlotFor`,
    // which already hand back a disposed scratch object once those flags
    // are set — well before the `await destroyWidgetAdView(...)` loop a
    // late callback could land during. Uses `_TeardownRaceBridge`
    // (round-16) to park dispose() in that exact await and confirm the
    // existing defence actually holds, not just in theory.
    test(
        'banner onAdLoadFailedCallback landing WHILE dispose() is still '
        'destroying the AdView is already a no-op via the scratch-slot '
        'fallback', () async {
      final b = _TeardownRaceBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      await a.preloadBanner('k');
      final slot = a.bannerSlot('k');
      final stale = b.widget!;

      final disposing = a.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(b.destroyWidgetAdViewCalls, isNotEmpty,
          reason: 'control — dispose() really is parked in the destroy '
              'await, which is the window under test');

      stale.onAdLoadFailedCallback('banner-id', _fakeError());

      // T114 round-1 review finding — check BEFORE completing the destroy
      // gate. dispose()'s own reset-loop runs AFTER the destroy-await
      // completes and unconditionally clears `lastErrorAt` to null; asserting
      // only after `await disposing` is a false negative that passes even if
      // the callback DID mutate the real slot moments earlier — this check
      // has to land inside the exact race window, before that loop ever runs.
      expect(slot.lastErrorAt, isNull,
          reason: 'a load failure landing mid-teardown must not touch the '
              'REAL slot — it should have been routed to a disposed '
              'scratch object instead');

      b.destroyGate.complete();
      await disposing;
    });
  });

  // Round-29 audit follow-up (MAJOR) — AppLovin wires ONE persistent
  // listener per ad type at initialize() time, so unlike AdMob (fresh
  // closure per show() call) it had no way to tell a stale cycle's late
  // native event apart from the current one. Fixed via `_interstitialAd`/
  // `_rewardedAd` ad-identity tracking (`identical()`-checked in every
  // show-lifecycle callback) — see applovin_adapter.dart.
  group('round-29 audit follow-up (MAJOR): cross-cycle late callback must '
      'not hijack a newer show cycle', () {
    test(
        'interstitial — a stale cycle\'s late display-failed does not steal '
        'a newer cycle\'s caller or tear down its slot', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      addTearDown(a.dispose);

      final ad1 = _fakeAd();
      await a.loadInterstitial();
      b.inter!.onAdLoadedCallback(ad1);
      bool? result1;
      await a.showInterstitial(onDone: (s) => result1 = s);
      b.inter!.onAdHiddenCallback(ad1); // cycle 1 resolves normally
      expect(result1, isTrue);

      final ad2 = _fakeAd();
      await a.loadInterstitial();
      b.inter!.onAdLoadedCallback(ad2);
      bool? result2;
      await a.showInterstitial(onDone: (s) => result2 = s);

      // ad1's callbacks fire again late — simulates a duplicate/delayed
      // native delivery landing after cycle 2 already claimed the adapter.
      b.inter!.onAdDisplayFailedCallback(ad1, _fakeError());

      expect(result2, isNull,
          reason: 'cycle 2 is still genuinely showing — its caller must '
              'not be resolved by cycle 1\'s stale late arrival');
      expect(a.interstitialSlot.isShowing, isTrue,
          reason: 'cycle 2\'s slot must not be torn down by a stale cycle '
              '1 callback');
    });

    test(
        'rewarded — a stale cycle\'s late hidden does not steal a newer '
        'cycle\'s reward callback', () async {
      final b = FakeAppLovinBridge();
      final a = AppLovinAdapter(bridge: b);
      expect(await a.initialize(_config), isTrue);
      addTearDown(a.dispose);

      final ad1 = _fakeAd();
      await a.loadRewarded();
      b.rewarded!.onAdLoadedCallback(ad1);
      RewardResult? result1;
      await a.showRewarded(onDone: (r) => result1 = r);
      b.rewarded!.onAdHiddenCallback(ad1); // cycle 1 resolves (no reward)
      expect(result1?.earned, isFalse);

      final ad2 = _fakeAd();
      await a.loadRewarded();
      b.rewarded!.onAdLoadedCallback(ad2);
      RewardResult? result2;
      await a.showRewarded(onDone: (r) => result2 = r);

      // ad1's stale hidden callback fires again late.
      b.rewarded!.onAdHiddenCallback(ad1);

      expect(result2, isNull,
          reason: 'a user genuinely still watching cycle 2 must not have '
              'its reward callback resolved by cycle 1\'s stale late '
              'hidden event — this is exactly how a real reward could be '
              'lost');
      expect(a.rewardedSlot.isShowing, isTrue);
    });
  });
}
