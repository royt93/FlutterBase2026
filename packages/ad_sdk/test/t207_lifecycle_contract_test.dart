import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// codex round-1 fix — lets a test hold `initialize()` open so it can call
/// `destroy()` WHILE init is still in flight, not merely after it settles.
///
/// codex round-2 fix — [entered] completes the moment this override is
/// actually invoked, BEFORE awaiting [initGate]. Without waiting on
/// [entered] first, a test calling `destroy()` right after starting
/// `initialize()` could easily race ahead of the several async steps
/// (GAID resolve, VIP load, ConsentManager bootstrap, ...) that run before
/// the adapter's own `initialize()` is ever reached — superseding the
/// attempt at one of THOSE earlier guards instead of genuinely racing
/// native init, while still reporting a passing test either way.
class _HoldableInitAdapter extends FakeAdProviderAdapter {
  final Completer<void> entered = Completer<void>();
  final Completer<void> initGate = Completer<void>();

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    entered.complete();
    await initGate.future;
    return super.initialize(config,
        deviceGaid: deviceGaid,
        isAgeRestrictedUser: isAgeRestrictedUser,
        consent: consent);
  }
}

/// codex round-2 fix — counts real `onAppPaused()`/`onAppResumed()`
/// invocations so a test can prove `didChangeAppLifecycleState` dispatched
/// through the real `WidgetsBinding` actually reached this adapter, instead
/// of just checking that the manager didn't throw (which would still pass
/// even if `initialize()` stopped registering the observer entirely).
class _LifecycleCountingAdapter extends FakeAdProviderAdapter {
  int pausedCalls = 0;
  int resumedCalls = 0;

  // codex round-3 fix — AdManager only calls onAppResumed() AFTER
  // _resumeAdWorkAfterConsent's consent re-check settles (allowed up to 5s
  // in production). Waiting on this real signal, bounded, is more correct
  // than a fixed real-time delay guessed to be "long enough".
  final Completer<void> resumed = Completer<void>();

  @override
  void onAppPaused() {
    pausedCalls++;
    super.onAppPaused();
  }

  @override
  void onAppResumed() {
    resumedCalls++;
    if (!resumed.isCompleted) resumed.complete();
    super.onAppResumed();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = AdManager();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    await manager.destroy();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    manager.debugConfig = null;
    manager.debugSetAdapter(FakeAdProviderAdapter());
    manager.debugConfig = const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'test',
        interstitialId: 'test',
        rewardedId: 'test',
        appOpenId: 'test',
      ),
      safety: AdSafetyParams(dryRun: true, minSessionDurationBeforeAd: 0),
    );
  });

  tearDown(() async {
    await manager.destroy();
    manager.debugConfig = null;
    manager.debugSetAdapter(null);
  });

  test('load/show lifecycle returns to idle and remains reusable', () async {
    await manager.loadInterstitial();
    expect(manager.adapter!.interstitialSlot.isReady, isTrue);
    var shown = false;
    await manager.showInterstitial(onDoneFlow: (value) => shown = value);
    expect(shown, isTrue);
    expect(manager.adapter!.interstitialSlot.isShowing, isFalse);
    expect(manager.adapter!.interstitialSlot.isLoading, isFalse);
    await manager.loadInterstitial();
    expect(manager.adapter!.interstitialSlot.isReady, isTrue);
  });

  test('destroy is idempotent and clears adapter/session state', () async {
    await manager.loadRewardedAd();
    final first = manager.destroy();
    final second = manager.destroy();
    await Future.wait([first, second]);
    expect(manager.isInitialised, isFalse);
    expect(manager.adapter, isNull);
    await manager.destroy();
  });

  test('destroy during an in-flight show leaves no fullscreen busy state',
      () async {
    manager.adapter!.interstitialSlot.beginLoad();
    manager.adapter!.interstitialSlot.markReady();
    manager.adapter!.interstitialSlot.beginShow();
    expect(manager.fullscreenBusy.value, isTrue);
    await manager.destroy();
    expect(manager.fullscreenBusy.value, isFalse);
    expect(manager.adapter, isNull);
  });

  test('a fresh adapter can be installed after destroy without stale state',
      () async {
    await manager.destroy();
    final replacement = FakeAdProviderAdapter();
    manager.debugSetAdapter(replacement);
    manager.debugConfig = const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'test',
        interstitialId: 'test',
        rewardedId: 'test',
        appOpenId: 'test',
      ),
      safety: AdSafetyParams(dryRun: true, minSessionDurationBeforeAd: 0),
    );
    await manager.loadInterstitial();
    expect(replacement.interstitialSlot.isReady, isTrue);
    expect(manager.adapter, same(replacement));
  });

  group(
      'T207 audit fix — the full documented chain, through the REAL '
      'initialize()/destroy() path (not debugSetAdapter/debugConfig, which '
      'every test above this bypasses everything through)', () {
    const config = AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'test',
        interstitialId: 'test',
        rewardedId: 'test',
        appOpenId: 'test',
      ),
      autoRequestUmpConsent: false,
      // Not under test here — the default `auto` grants a first-install VIP
      // grace period, which would suppress every ad surface this group's
      // tests exercise (same reasoning as ump_consent_round5_test.dart).
      firstInstallVipGrace: FirstInstallVipGrace.disabled,
      safety: AdSafetyParams(dryRun: true, minSessionDurationBeforeAd: 0),
    );

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const alChannel = MethodChannel('applovin_max');
    const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

    setUp(() {
      manager.debugSetAdapter(null);
      manager.debugConfig = null;
      // A fresh instance per call — same as the real default factory
      // (`config.isAdMob ? AdMobAdapter() : AppLovinAdapter()`), and
      // required here: reusing one instance across a destroy()+reinitialize
      // would hand the second initialize() an adapter whose slot
      // notifiers the first destroy() already disposed.
      AdManager.debugAdapterFactory = (_) => _LifecycleCountingAdapter();
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    });

    tearDown(() {
      AdManager.debugAdapterFactory = null;
      messenger.setMockMethodCallHandler(alChannel, null);
      messenger.setMockMethodCallHandler(gmaChannel, null);
    });

    test(
        'initialize → load → show → background → foreground → destroy → '
        'reinitialize, end to end', () async {
      var initCalls = 0;
      await manager.initialize(
        config: config,
        onComplete: (success, gaid) {
          initCalls++;
          expect(success, isTrue);
        },
      );
      expect(manager.isInitialised, isTrue);
      expect(initCalls, 1);
      final firstAdapter = manager.adapter;
      expect(firstAdapter, isNotNull);
      // A real connectivity watch answers `false` in a unit-test process —
      // same seam used by fast_refill_rewarded_interstitial_test.dart and
      // init_post_success_throw_test.dart to fake "online" without a real
      // platform channel.
      manager.debugConnectivityReady = false;
      manager.debugConnectivityChanged(true);

      await manager.loadInterstitial();
      expect(firstAdapter!.interstitialSlot.isReady, isTrue);

      var shown = false;
      await manager.showInterstitial(onDoneFlow: (v) => shown = v);
      expect(shown, isTrue);

      // Background: dispatched through the REAL binding (codex round-1 fix)
      // — calling manager.didChangeAppLifecycleState(...) directly would
      // still pass even if initialize() never actually registered AdManager
      // via WidgetsBinding.instance.addObserver(this). Going through
      // handleAppLifecycleStateChanged() proves that registration is real.
      final countingAdapter = firstAdapter as _LifecycleCountingAdapter;
      WidgetsBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      WidgetsBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // codex round-3 fix — onAppResumed() only fires after
      // _resumeAdWorkAfterConsent's consent re-check settles (allowed up to
      // 5s in production) — wait on the real signal, bounded, rather than a
      // fixed delay guessed to be "long enough".
      await countingAdapter.resumed.future
          .timeout(const Duration(seconds: 10));

      // codex round-2 fix — an observable side effect, not just "didn't
      // throw": proves the dispatch above genuinely reached the adapter
      // through AdManager's real WidgetsBindingObserver registration.
      expect(countingAdapter.pausedCalls, 1);
      expect(countingAdapter.resumedCalls, 1);

      await manager.destroy();
      expect(manager.isInitialised, isFalse);
      expect(manager.adapter, isNull);

      var secondInitCalls = 0;
      await manager.initialize(
        config: config,
        onComplete: (success, gaid) {
          secondInitCalls++;
          expect(success, isTrue);
        },
      );
      expect(manager.isInitialised, isTrue);
      expect(secondInitCalls, 1);
      final secondAdapter = manager.adapter;
      expect(secondAdapter, isNotNull);
      expect(secondAdapter, isNot(same(firstAdapter)),
          reason: 'reinitialize must build a genuinely fresh adapter, not '
              'reuse the torn-down one');
      manager.debugConnectivityReady = false;
      manager.debugConnectivityChanged(true);

      // The reinitialized session must be fully usable, not left in a
      // stale state by the earlier background/resume cycle.
      await manager.loadInterstitial();
      expect(secondAdapter!.interstitialSlot.isReady, isTrue);
    });

    test('concurrent initialize() calls join the same in-flight attempt, '
        'and BOTH callers are told the real result', () async {
      bool? firstResult;
      bool? secondResult;
      final first = manager.initialize(
          config: config, onComplete: (success, __) => firstResult = success);
      final second = manager.initialize(
          config: config, onComplete: (success, __) => secondResult = success);
      await Future.wait([first, second]);
      expect(manager.isInitialised, isTrue);
      // codex round-2 fix — Future.wait alone only proves both futures
      // completed, not that the SECOND (queued/joined) caller's onComplete
      // callback was actually invoked with the real, correct result. A
      // dropped or wrongly-valued queued callback would still pass without
      // this.
      expect(firstResult, isTrue);
      expect(secondResult, isTrue,
          reason: 'the joined/queued caller must also be told the real '
              'init result, not be silently dropped');
    });

    test(
        'codex round-1 fix — a destroy() that genuinely arrives WHILE '
        'initialize() is still awaiting native init leaves a clean, '
        'reinitializable state (not just after both settle)', () async {
      final holdable = _HoldableInitAdapter();
      AdManager.debugAdapterFactory = (_) => holdable;

      final initFuture =
          manager.initialize(config: config, onComplete: (_, __) {});
      // codex round-2 fix — wait for the adapter's own initialize() override
      // to actually be ENTERED before calling destroy(). Without this,
      // destroy() could easily race ahead of the several async steps
      // (GAID resolve, VIP load, ConsentManager bootstrap) that run BEFORE
      // native init and supersede the attempt at one of those earlier
      // guards instead — a real regression in native-init cancellation
      // specifically would go unnoticed.
      await holdable.entered.future;
      // The adapter's own initialize() is now genuinely parked on
      // initGate — the manager is mid NATIVE init here, not merely
      // somewhere earlier in the init pipeline.
      expect(manager.isInitialised, isFalse);

      await manager.destroy();
      expect(manager.isInitialised, isFalse);
      expect(manager.adapter, isNull);

      // Release the stale attempt now — it must not install itself into the
      // torn-down manager once it finally resolves.
      holdable.initGate.complete();
      await initFuture;
      expect(manager.isInitialised, isFalse,
          reason: 'a destroy() that arrived mid-init superseded this '
              'attempt — it must not resurrect isInitialised/adapter once '
              'its stale native init call finally completes');
      expect(manager.adapter, isNull);

      // The manager must still be genuinely reinitializable afterward.
      // `holdable` is single-use (its `entered`/`initGate` completers are
      // already spent) — a fresh adapter for this second, real init.
      AdManager.debugAdapterFactory = (_) => FakeAdProviderAdapter();
      await manager.initialize(config: config, onComplete: (_, __) {});
      expect(manager.isInitialised, isTrue);
      manager.debugConnectivityReady = false;
      manager.debugConnectivityChanged(true);
      await manager.loadRewardedAd();
      expect(manager.adapter!.rewardedSlot.isReady, isTrue);
    });
  });
}
