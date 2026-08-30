// Round-25 (found on an iOS Simulator run, 2026-08-26) — what happens when
// `AdManager.initialize()` throws AFTER the native adapter is already up.
//
// Two defects met there:
//
//  1. The two footgun `assert(false, ...)` calls (no consent flow / no
//     requestAtt on iOS) ran BEFORE `onComplete(true)` and the
//     `BoolEvent(true)`. In any debug or profile build the assert throws, the
//     init body's `catch` swallows it, and the host was never told init had
//     finished — so a splash following the documented contract (README step 3:
//     listen for the init event) waited for an event that could not arrive and
//     fell through to its hard-cap timer. Native init had actually succeeded.
//
//  2. That swallowed throw then scheduled an init auto-retry. The retry budget
//     is reset to 0 the moment the adapter's own init succeeds, so the retry
//     could never be spent: every attempt re-initialised the adapter fine,
//     threw again at the same later step, reset the budget and armed "retry
//     #1" once more — a permanent 5-second loop that disposed and rebuilt the
//     native adapter and re-requested ads each round. Observed live on the
//     Simulator with `--dart-define=SKIP_ATT=true`.
//
// Both are driven here through the real `initialize()` body, with only the
// adapter swapped via `AdManager.debugAdapterFactory`.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Polls a condition instead of sleeping a fixed span. The retry backoff is
/// driven by `AdManager.debugInitRetryDelays`, but the attempt still has real
/// async work (VIP load, consent bootstrap) ahead of it, so the wall-clock
/// distance to "the retry has started" is not a constant.
Future<void> _pumpUntil(bool Function() done,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Counts what actually reached the native layer. The show paths answer their
/// callback `false` for many reasons (an unloaded slot among them), so "the
/// adapter was never asked" is the only observable that separates "refused
/// because a teardown is in flight" from "refused incidentally".
class _ShowCountingAdapter extends _OkAdapter {
  int showAppOpenCalls = 0;

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    showAppOpenCalls++;
    onDismiss(true);
  }
}

/// Round-25 QC round 13 (`codex`, MAJOR) — the VIP "watch a real rewarded ad to
/// extend your window" path. `loadRewarded` only flips the slot to `loading`;
/// the test decides when it becomes ready, which is what makes the window
/// `_loadRewardedOnDemand` awaits long enough to start a `destroy()` inside it.
class _OnDemandRewardedAdapter extends _OkAdapter {
  int loadRewardedCalls = 0;
  int showRewardedCalls = 0;

  @override
  Future<void> loadRewarded({void Function(bool)? onAdLoaded}) async {
    loadRewardedCalls++;
    rewardedSlot.beginLoad();
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    onDone(const RewardResult(earned: true, shown: true));
  }
}

class _OkAdapter implements AdProviderAdapter {
  int initializeCalls = 0;

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  @override
  String get tag => 'FakeAdapter';

  @override
  AdEventSink? eventSink;

  @override
  bool Function() canReload = () => true;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    initializeCalls++;
    return true;
  }

  // The post-success path fires these off; they must return a real Future or
  // the `unawaited(...)` calls in initialize() blow up for the wrong reason.
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> loadInterstitial({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> loadRewarded({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> applyConsent(AdConsent consent) async {}
  int disposeCalls = 0;
  @override
  Future<void> dispose() async => disposeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts the first round of ad requests, so a test can prove the preloads
/// happen at all (and do NOT happen on a footgun config).
class _CountingAdapter extends _OkAdapter {
  int banners = 0;
  int mrecs = 0;
  int appOpens = 0;

  @override
  Future<void> preloadBanner(Object key) async => banners++;
  @override
  Future<void> preloadMrec(Object key) async => mrecs++;
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async =>
      appOpens++;
}

class _FailingAdapter extends _OkAdapter {
  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    initializeCalls++;
    return false;
  }
}

/// Round-25 QC — an adapter whose own `initialize()` succeeds but that throws
/// in a step `AdManager.initialize()` runs AFTER assigning `_adapter`. That is
/// the only way into the "adapter up, init still failed" branch of the catch,
/// and all three independent reviewers found it: without disposing first, the
/// host is told `false` while `isInitialised` still answers `true` and the live
/// adapter leaks for the rest of the process.
class _ThrowsAfterInitAdapter extends _OkAdapter {
  bool _armed = false;
  final AdSlot _inter = AdSlot(type: AdSlotType.interstitial);

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    final ok = await super.initialize(config,
        deviceGaid: deviceGaid,
        isAgeRestrictedUser: isAgeRestrictedUser,
        consent: consent);
    // Armed only once native init has already reported success, so the throw
    // below lands strictly inside the window this test is about.
    _armed = true;
    return ok;
  }

  // Deliberately a slot GETTER and not an `async` method: the first attempt
  // threw from `applyConsent` declared `async`, so the throw surfaced as an
  // unhandled async error and never reached the `catch` at all — init still
  // succeeded and the test read green-ish for the wrong reason. (A
  // *synchronous* throw from `applyConsent` does land in the `catch`; that is
  // `_ConsentApplyThrowsAdapter` below, which needs the later throw point to
  // reach a window where a consent listener is already attached.)
  //
  // Round 4 correction, from reading the real stack trace: this getter is read
  // by the `_adapter` setter itself — `_attachFullscreenBusySlotListeners()`,
  // ad_manager.dart:117, reached from the `_adapter = adapter` assignment —
  // not by `_attachFullscreenDismissWatchers()` on the next line, which is
  // simply never reached. Either way the throw is inside the try and lands in
  // the failure branch, which is what the test is about; the comment just used
  // to name the wrong line, and `claude` was right to flag it.
  //
  // Throws exactly ONCE and then disarms: the SDK's own teardown reads the
  // same slot while detaching listeners, and a getter that kept throwing would
  // break the dispose this test is asserting instead of the init step.
  @override
  AdSlot get interstitialSlot {
    if (_armed) {
      _armed = false;
      throw StateError('slot read blew up after init succeeded');
    }
    return _inter;
  }
}

/// Round-25 QC round 2 (both independent reviewers, MAJOR) — the same
/// post-init throw, plus a native `dispose()` that throws on the way out. A
/// plugin's dispose CAN throw (the file says so elsewhere), and the teardown
/// used to abandon the two null-outs when it did: the host was told init
/// failed while `isInitialised` still answered `true`, which is the exact
/// contradiction the round-25 fix exists to remove — reached through the error
/// path instead of the happy one.
class _DisposeThrowsAdapter extends _ThrowsAfterInitAdapter {
  @override
  Future<void> dispose() async {
    await super.dispose();
    throw StateError('native dispose blew up');
  }
}

/// Round-25 QC round 3 (`codex`, MAJOR) — throws on the way IN *and* on the
/// way out: the slot getter blows up twice, so the second throw lands inside
/// the listener detach that runs before `dispose()`. With one shared guard
/// around the whole teardown, that throw skipped `dispose()` entirely and the
/// native adapter was never told to go away — a leak on the one path where the
/// SDK already knows the adapter is broken.
class _TeardownThrowsAdapter extends _OkAdapter {
  bool _armed = false;
  bool _teardownArmed = false;
  final AdSlot _inter = AdSlot(type: AdSlotType.interstitial);
  final AdSlot _appOpen = AdSlot(type: AdSlotType.appOpen);

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    final ok = await super.initialize(config,
        deviceGaid: deviceGaid,
        isAgeRestrictedUser: isAgeRestrictedUser,
        consent: consent);
    _armed = true;
    return ok;
  }

  // Gets init into the post-success failure branch (through the `_adapter`
  // setter, see `_ThrowsAfterInitAdapter`), then arms the SECOND throw for the
  // teardown that follows. `appOpenSlot` is read twice while tearing down —
  // once by `old.appOpenSlot.state.removeListener(...)`, the step that used to
  // take `dispose()` down with it, and once by the `_adapter = null` setter,
  // which is what the raw-field fallback exists for.
  @override
  AdSlot get interstitialSlot {
    if (_armed) {
      _armed = false;
      _teardownArmed = true;
      throw StateError('slot read blew up after init succeeded');
    }
    return _inter;
  }

  @override
  AdSlot get appOpenSlot {
    if (_teardownArmed) throw StateError('slot read blew up during teardown');
    return _appOpen;
  }
}

// autoRequestUmpConsent: false with no setConsent()/requestUmpConsent() call
// is exactly the combination the consent footgun diagnostic exists to shout
// about.
const _admobIds = AdMobConfig(
  bannerId: 'b',
  interstitialId: 'i',
  appOpenId: 'ao',
  rewardedId: 'r',
);

// The same config with the footgun switched off, for the tests that are about
// the retry loop rather than the assert.
//
// Every config in this file disables the first-install VIP grace, and that is
// load-bearing rather than tidiness. The default grace grants a (30s in debug)
// VIP entry on a fresh store, a VIP member skips every preload, and the grant's
// disk write is queued: it lands on the NEXT test, after `setUp` has already
// reset SharedPreferences, through the plaintext fallback
// (`getVipEntriesFallbackRaw`) that `VipEntriesStore.getRaw` consults when the
// secure channel is unavailable — which it always is in a unit test. So a
// preload assertion read zero for a reason that had nothing to do with the code
// under test ("⏭️ banner/mrec preload skipped — VIP member"), and no amount of
// clearing prefs in `setUp` could fix it because the write had not landed yet.
// Granting no VIP anywhere in the file is what makes these tests
// order-independent.
const _okConfig = AdConfig(
  provider: AdProvider.admob,
  admob: _admobIds,
  safety: AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

const _footgunConfig = AdConfig(
  provider: AdProvider.admob,
  autoRequestUmpConsent: false,
  admob: _admobIds,
  safety: AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

// Same post-init throw as `_TeardownThrowsAdapter`, but the throwing slot
// getter first disposes the `ConsentManager` singleton's notifier. That makes
// the very next teardown step — removing `_syncConsentToAdapter` from
// `consentManager.listenable` — throw an AssertionError from `ChangeNotifier`'s
// own disposed check. Not synthetic: `ConsentManager` is a static singleton
// that survives the adapter, and anything (a test harness, a host calling
// `resetForTest`, a future dispose on the manager) can retire that notifier
// between init and teardown.
class _ConsentKillingAdapter extends _OkAdapter {
  bool _armed = false;
  final AdSlot _inter = AdSlot(type: AdSlotType.interstitial);

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    final ok = await super.initialize(config,
        deviceGaid: deviceGaid,
        isAgeRestrictedUser: isAgeRestrictedUser,
        consent: consent);
    _armed = true;
    return ok;
  }

  @override
  AdSlot get interstitialSlot {
    if (_armed) {
      _armed = false;
      ConsentManager.resetForTest();
      throw StateError('slot read blew up after init succeeded');
    }
    return _inter;
  }
}

// Holds its own `initialize()` open until the test releases it, so a second
// `initialize()` call can be made while the first is genuinely still running.
class _SlowAdapter extends _OkAdapter {
  final gate = Completer<void>();

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    await gate.future;
    return super.initialize(config,
        deviceGaid: deviceGaid,
        isAgeRestrictedUser: isAgeRestrictedUser,
        consent: consent);
  }
}

// Teardown is held open: `dispose()` parks on a gate, so a test can hold
// `destroy()` inside its own awaits and call `destroy()` a second time from
// there (round-8 MAJOR — the second call used to run a whole extra teardown).
class _SlowDisposeAdapter extends _OkAdapter {
  final gate = Completer<void>();

  @override
  Future<void> dispose() async {
    await gate.future;
    return super.dispose();
  }
}

// Native init is held open and then FAILS (returns false) — the branch that
// used to arm a retry timer and fire `BoolEvent(false)` even when the attempt
// had already been superseded by `destroy()`.
class _SlowFailingAdapter extends _OkAdapter {
  final gate = Completer<void>();

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    await gate.future;
    return false;
  }
}

// Native init is held open and then THROWS, so the attempt lands in
// `initialize()`'s outer `catch` — the branch that decided what to tear down by
// reading the shared `_adapter`/`_config` fields.
class _SlowThrowingInitAdapter extends _OkAdapter {
  final gate = Completer<void>();

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    await gate.future;
    throw StateError('native init blew up long after the host gave up');
  }
}

// A `_ThrowsAfterInitAdapter` whose native init is also held open, so a second
// caller has time to park behind an attempt that is going to fail terminally.
class _SlowThrowsAfterInitAdapter extends _ThrowsAfterInitAdapter {
  final gate = Completer<void>();

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    await gate.future;
    return super.initialize(config,
        deviceGaid: deviceGaid,
        isAgeRestrictedUser: isAgeRestrictedUser,
        consent: consent);
  }
}

// Tears the whole SDK down from inside `applyConsent`, i.e. in the window
// *after* `_config`/`_adapter` are installed but *before* init reports success
// — `destroy()` bumps `_initGen` synchronously at its top, so the resuming init
// body sees itself superseded. Round-25 QC round 5's second abort check.
class _DestroyOnConsentAdapter extends _OkAdapter {
  var destroyed = false;

  @override
  Future<void> applyConsent(AdConsent consent) {
    if (!destroyed) {
      destroyed = true;
      unawaited(AdManager().destroy());
    }
    return super.applyConsent(consent);
  }
}

// Throws from `applyConsent`, which `initialize()` calls SYNCHRONOUSLY (the
// interface declares `void applyConsent(...)`) one step *after* it has attached
// `_syncConsentToAdapter` to the consent listenable. That ordering is the whole
// point: it is the only window in which the failure branch has a consent
// listener to detach, so it is the only way to prove the detach happens. Note
// the override is deliberately NOT `async` — an `async` override turns the
// throw into an unhandled async error that never reaches the `catch`, the trap
// documented on `_ThrowsAfterInitAdapter`.
class _ConsentApplyThrowsAdapter extends _OkAdapter {
  // Not `async`: the base fake declares `Future<void>` (the interface itself
  // says `void`), and an `async` body would turn this into a rejected future
  // instead of a synchronous throw.
  @override
  Future<void> applyConsent(AdConsent consent) =>
      throw StateError('applyConsent blew up after init succeeded');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // applyConsentToProviders fires native calls on these channels (AppLovin's
  // are not awaited, so a MissingPluginException would surface as an
  // unhandled async error and fail the test) — same pattern as
  // ad_manager_coppa_recover_test.dart.
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Round-25 QC round 11 — every retry/teardown ordering test in this file
    // pins an ORDERING, never the production 5s/15s/30s backoff. Shortening it
    // here keeps them fast and, more importantly, non-flaky: they no longer
    // race a fixed wall-clock sleep against the attempt's own async work.
    AdManager.debugInitRetryDelays = const [Duration(milliseconds: 300)];
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    AdManager.debugInitRetryDelays = null;
    AdManager.debugLastInitRetryDelay = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'a footgun config after a successful native init still reports init '
      'completion to the host', () async {
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    var calls = 0;
    bool? reported;
    await AdManager().initialize(
      config: _footgunConfig,
      onComplete: (success, gaid) {
        calls++;
        reported = success;
      },
    );

    expect(calls, 1,
        reason: 'the host is told exactly once — a splash waiting on this '
            'callback/event is the documented integration contract');
    expect(reported, isTrue,
        reason: 'native init succeeded; the assert is a developer warning, '
            'not an init failure');
  });

  test('a footgun config does not arm an init auto-retry', () async {
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    await AdManager().initialize(
      config: _footgunConfig,
      onComplete: (_, __) {},
    );

    expect(AdManager().debugInitRetryScheduled, isFalse,
        reason: 'retrying cannot fix a config footgun, and the budget resets '
            'once the adapter is up — so a retry here loops forever');
  });

  test('a host onComplete that throws does not arm an init auto-retry',
      () async {
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    var calls = 0;
    var initEvent = 0;
    void onEvent(BoolEvent e) {
      if (e.value) initEvent++;
    }

    SimpleEventBus().listen(onEvent);
    addTearDown(() => SimpleEventBus().remove(onEvent));
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {
        calls++;
        throw StateError('host callback blew up');
      },
    );

    expect(calls, 1, reason: 'not called again by a retry attempt');
    expect(initEvent, 1,
        reason: 'a throwing host callback must not swallow the init-completion '
            'event the splash contract is built on');
    expect(AdManager().debugInitRetryScheduled, isFalse,
        reason: 're-running native init cannot fix a throwing host callback');
  });

  test(
      'a failure after the adapter came up disposes it before reporting, so '
      'isInitialised agrees with what the host was told', () async {
    final adapter = _ThrowsAfterInitAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    var calls = 0;
    bool? reported;
    var failEvents = 0;
    void onEvent(BoolEvent e) {
      if (!e.value) failEvents++;
    }

    SimpleEventBus().listen(onEvent);
    addTearDown(() => SimpleEventBus().remove(onEvent));

    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) {
        calls++;
        reported = success;
      },
    );

    expect(calls, 1, reason: 'reported once, not once per retry attempt');
    expect(reported, isFalse);
    expect(failEvents, 1,
        reason: 'a splash listening on the event bus must hear the failure '
            'too, not just the onComplete callback');
    expect(AdManager().isInitialised, isFalse,
        reason: 'the host was told init failed — the SDK must not simultaneously '
            'answer that it IS initialised, with a live native adapter and its '
            'listeners still wired up');
    expect(adapter.disposeCalls, 1,
        reason: 'clearing the fields is not enough — the native adapter itself '
            'has to be torn down, or it keeps serving ads for the rest of the '
            'process. Without this, replacing the `_disposeAdapter()` call '
            'with a raw pair of null-outs passes.');
    expect(AdManager().debugInitRetryScheduled, isFalse,
        reason: 're-running native init cannot fix a step that throws after it');
  });

  test(
      'an adapter whose dispose() throws still leaves the SDK saying it is '
      'not initialised', () async {
    final adapter = _DisposeThrowsAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    var calls = 0;
    bool? reported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) {
        calls++;
        reported = success;
      },
    );

    expect(calls, 1);
    expect(reported, isFalse);
    expect(adapter.disposeCalls, 1, reason: 'the teardown was attempted');
    expect(AdManager().isInitialised, isFalse,
        reason: 'a plugin that throws on the way out is not a reason for the '
            'SDK to keep claiming it is initialised — the host was already '
            'told the opposite');
  });

  test(
      'a host that re-initialises from onComplete(false) is not dropped by '
      'the in-progress guard', () async {
    // The obvious thing for a host to do when init fails is try again with a
    // fallback config. That call used to hit "initialize already in progress —
    // skipping duplicate" and vanish, because the flag is only released in the
    // outer `finally`, i.e. AFTER the callback returns.
    var built = 0;
    AdManager.debugAdapterFactory =
        (_) => built++ == 0 ? _ThrowsAfterInitAdapter() : _OkAdapter();
    Future<void>? second;
    // Each call reports through its own flag: a call the duplicate guard
    // refuses returns without ever invoking its `onComplete`, so these are
    // what tell "ran" apart from "silently dropped".
    var secondReported = false;
    var thirdReported = false;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) {
        if (!success && second == null) {
          second = AdManager().initialize(
            config: _okConfig,
            onComplete: (_, __) => secondReported = true,
          );
        }
      },
    );
    // The outer call's `finally` has already run by now, while the nested one
    // is still in flight. It must NOT have handed the nested call's
    // in-progress flag back to `false`, or a third caller (the internal retry
    // timer, a second splash) slips past the duplicate guard and the SDK ends
    // up building two adapters at once.
    final third = AdManager().initialize(
        config: _okConfig, onComplete: (_, __) => thirdReported = true);

    await second;
    await third;

    expect(secondReported, isTrue,
        reason: "the host's own retry from onComplete(false) must actually "
            'run, not hit "initialize already in progress" and vanish');
    // Round 4 changed what "refused" means for the third caller: it is parked
    // rather than dropped, so it IS reported — with the in-flight attempt's
    // own result — and it still must not build an adapter of its own. That is
    // the distinction `built` below carries.
    expect(thirdReported, isTrue,
        reason: 'a caller the duplicate guard turns away still has to hear the '
            'result of the attempt it was turned away for — being told nothing '
            'at all is what hangs a splash doing `await initialize()`');
    expect(built, 2,
        reason: 'the second initialize() must actually have run — and the '
            'third must have been refused: a third concurrent call slipping '
            'past the duplicate guard builds a second adapter on top of the '
            'live one');
    expect(AdManager().isInitialised, isTrue,
        reason: "the host's own retry has to be able to bring the SDK up");
  });

  test('a footgun config does not silently kill the retry timer and the '
      'connectivity watch', () async {
    // The asserts throw in debug/profile and the init `catch` swallows that
    // throw, so anything sequenced after them is lost. They used to sit above
    // the preloads, the ad retry timer and the connectivity watch — a
    // developer tripping the warning also lost all three for the session,
    // which reads as "ads never load on my machine", nothing like the warning
    // that caused it.
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    // Deltas, not absolutes: both counters live on the singleton and are NOT
    // reset by destroy(), so an earlier test in this file leaves them above
    // zero and `greaterThan(0)` would pass even with the services skipped.
    final retryGenBefore = AdManager().debugRetryGen;
    final connGenBefore = AdManager().debugConnectivityWatchGen;

    await AdManager().initialize(
      config: _footgunConfig,
      onComplete: (_, __) {},
    );

    expect(AdManager().debugRetryGen, greaterThan(retryGenBefore),
        reason: 'the ad retry timer must still have been started');
    expect(AdManager().debugConnectivityWatchGen, greaterThan(connGenBefore),
        reason: 'the connectivity watch must still have been started');
  });

  test('a clean init really does fire the first round of ad requests',
      () async {
    // Pins the preload calls themselves: without this, deleting all three is a
    // mutation every other test in this file survives.
    final adapter = _CountingAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    // Consent has to be granted first, or nothing is requested for a reason
    // that has nothing to do with the preload calls: the default
    // `autoRequestUmpConsent` closes the ad gate until UMP resolves, and UMP
    // cannot resolve in a unit test. Granting it also clears the footgun, which
    // is why this config leaves `autoRequestUmpConsent` at its default.
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));

    final skips = <AdSkipEvent>[];
    final sub = AdManager().events.listen((e) {
      if (e is AdSkipEvent) skips.add(e);
    });

    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);

    // Banner + MREC only. The App Open request goes through
    // `loadAppOpenAd()`, which has its own consent gate and skips while UMP is
    // unresolved (`⏭️ loadAppOpen skipped — consent not granted (UMP)`) — in a
    // unit test the UMP channel does not exist, so asserting it would be
    // asserting the gate, not the preload block.
    expect(adapter.banners, 1);
    expect(adapter.mrecs, 1);
    // The App Open request cannot be asserted on the adapter (see above), but
    // it can be asserted on the orchestrator: `loadAppOpenAd()` publishes an
    // `AdSkipEvent(action: 'load', reason: 'consent')` when its own gate turns
    // it away. That event only exists if the preload block really called it, so
    // deleting the App Open preload — a mutation the two adapter counters above
    // survive, per `agy`'s round-3 review — turns this red.
    expect(
        skips.where((e) =>
            e.type == AdSlotType.appOpen &&
            e.action == 'load' &&
            e.reason == 'consent'),
        isNotEmpty,
        reason: 'the initial preload round has to at least ATTEMPT the App '
            'Open load, even when its consent gate then declines it');
    await sub.cancel();
  });

  test('a footgun config requests no ads at all, in any build', () async {
    // The compliance half of the assert move. The asserts now fire after the
    // preload block instead of before it, so the block itself has to be what
    // refuses to request ads with no consent coverage — in debug exactly as in
    // release, where `_applyConsentFootgunGuard` blocks. Before this, moving
    // the assert down meant a footgun config started requesting ads in
    // debug/profile, which is not the SDK's call to make.
    final adapter = _CountingAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(
      config: _footgunConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(adapter.appOpens, 0);
    expect(adapter.banners, 0);
    expect(adapter.mrecs, 0);
  });

  test('a host onComplete(false) that throws still fires the failure event and '
      'does not escape initialize()', () async {
    // The failure report used to be uncontained while the success report was:
    // a throwing host callback escaped `initialize()` (blowing up the host's
    // own `await`) and skipped `BoolEvent(false)`, so a splash listening on the
    // event bus rather than the callback waited for a signal that never came.
    AdManager.debugAdapterFactory = (_) => _ThrowsAfterInitAdapter();
    var failEvents = 0;
    void onEvent(BoolEvent e) {
      if (!e.value) failEvents++;
    }

    SimpleEventBus().listen(onEvent);
    addTearDown(() => SimpleEventBus().remove(onEvent));

    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) {
        if (!success) throw StateError('host failure callback blew up');
      },
    );

    expect(failEvents, 1);
  });

  test('an adapter-init failure still arms the auto-retry it always did',
      () async {
    final failing = _FailingAdapter();
    AdManager.debugAdapterFactory = (_) => failing;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );

    expect(failing.initializeCalls, 1);
    expect(AdManager().debugInitRetryScheduled, isTrue,
        reason: 'the pre-existing bounded retry for a genuinely failed native '
            'init must be untouched by the post-success fix');
  });
  test(
      'a broken slot getter during teardown does not cost the adapter its '
      'dispose()', () async {
    final adapter = _TeardownThrowsAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    bool? reported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => reported = success,
    );

    expect(reported, isFalse);
    expect(adapter.disposeCalls, 1,
        reason: 'the detach throwing must not skip the native dispose — one '
            'shared guard around the whole teardown leaked the adapter here');
    expect(AdManager().isInitialised, isFalse);
  });

  test('a host onLog sink that throws cannot strand the SDK as initialised',
      () async {
    // `onLog` is host code, and the interesting logs happen exactly when
    // something is already broken: the adapter teardown logs from inside its
    // own catch. A throwing sink there used to skip the state reset, so the
    // host was told init failed while `isInitialised` still said true.
    final adapter = _DisposeThrowsAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    var sinkCalls = 0;
    bool? reported;
    await AdManager().initialize(
      config: AdConfig(
        provider: AdProvider.admob,
        admob: _admobIds,
        safety: const AdSafetyParams(dryRun: true),
        firstInstallVipGrace: FirstInstallVipGrace.disabled,
        onLog: (level, tag, msg) {
          sinkCalls++;
          throw StateError('the host logger blew up');
        },
      ),
      onComplete: (success, _) => reported = success,
    );

    expect(sinkCalls, greaterThan(0), reason: 'the sink was really installed');
    expect(reported, isFalse);
    expect(AdManager().isInitialised, isFalse);
  });

  test('a footgun config still shouts at the developer', () async {
    // The two `assert(false, ...)` calls are gone (they threw into this
    // method's own catch and never crashed anything). What replaced them is a
    // `SafeLogger.critical`, which reaches the host's own log sink and is not
    // silenced by `AdLogLevel.none` — so it needs pinning, or deleting the
    // diagnostic entirely is a mutation every other test in this file survives.
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    final errors = <String>[];
    await AdManager().initialize(
      config: AdConfig(
        provider: AdProvider.admob,
        autoRequestUmpConsent: false,
        admob: _admobIds,
        safety: const AdSafetyParams(dryRun: true),
        firstInstallVipGrace: FirstInstallVipGrace.disabled,
        logLevel: AdLogLevel.none,
        onLog: (level, tag, msg) {
          if (level == AdLogLevel.error) errors.add(msg);
        },
      ),
      onComplete: (_, __) {},
    );

    expect(errors.where((m) => m.contains('consent')), isNotEmpty,
        reason: 'a config that can never gather consent has to be impossible '
            'to miss, even for a host that turned logging off');
  });

  test('a retired consent notifier does not cost the adapter its teardown',
      () async {
    // Round-25 QC round 3 (`claude`, MAJOR): the failure branch ran
    // `removeListener` and `await _disposeAdapter()` inside ONE try, so a
    // throw from the first line would skip the teardown and leave the host
    // with `onComplete(false)` while `isInitialised` still answered true.
    //
    // Read this test for what it is. It does NOT go red if the guard inside
    // `_detachConsentListener()` is deleted, and that was measured, not
    // assumed: Flutter's `ChangeNotifier.removeListener` is documented as
    // safe to call after `dispose()`, and `ConsentManager`'s constructor is
    // private so no test can inject a `listenable` that throws. The reported
    // MAJOR is therefore unreachable in this code, and the fix is the
    // statement split (each teardown step independent), not the catch. What
    // this test does pin is the closest reachable thing: the consent singleton
    // being retired mid-init — `ConsentManager.resetForTest()` from inside the
    // throwing slot getter — must still leave the SDK fully torn down.
    AdManager.debugAdapterFactory = (_) => _ConsentKillingAdapter();
    bool? reported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => reported = success,
    );

    expect(reported, isFalse);
    expect(AdManager().isInitialised, isFalse,
        reason: 'a broken consent-listener removal must not cost the adapter '
            'its teardown');
  });

  test('a slot getter that throws from the adapter setter still clears the '
      'SDK state', () async {
    // Pins the second guard in `_disposeAdapter()` — the one around
    // `_adapter = null`. That assignment is not a plain field write: the
    // setter detaches and re-attaches the fullscreen-busy listeners, reading
    // all four slots on the way. `_TeardownThrowsAdapter` leaves `appOpenSlot`
    // throwing for good, so the setter itself throws, and without the
    // fallback to the raw `_adapterField` the exception escapes
    // `_disposeAdapter()` with both fields still set.
    AdManager.debugAdapterFactory = (_) => _TeardownThrowsAdapter();
    bool? reported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => reported = success,
    );

    expect(reported, isFalse);
    expect(AdManager().isInitialised, isFalse);
  });

  test('a caller parked by the duplicate guard is told the in-flight result',
      () async {
    // Round-25 QC round 4 (`codex`, MAJOR). The duplicate guard used to log
    // "skipping duplicate" and return, so the second caller was told nothing —
    // no `onComplete`, no `BoolEvent`. A splash doing `await initialize()` as
    // the second caller (a retry timer, a second route, a plugin doing its own
    // init) waited forever on a callback that could not arrive. It now hears
    // the real result of the attempt it was turned away for, and — the other
    // half of the contract — still does not build an adapter of its own.
    var built = 0;
    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory = (_) {
      built++;
      return slow;
    };

    bool? firstResult;
    bool? parkedResult;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => firstResult = success,
    );
    // Give the first call time to reach the adapter's (blocked) init.
    await Future<void>.delayed(Duration.zero);
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => parkedResult = success,
    );
    expect(parkedResult, isNull, reason: 'parked, not answered early');

    slow.gate.complete();
    await first;

    expect(firstResult, isTrue);
    expect(parkedResult, isTrue,
        reason: 'the parked caller must hear the same success the first caller '
            'heard, not silence');
    expect(built, 1, reason: 'parking must not build a second adapter');
  });

  test('a parked caller hears a failure too, and again on destroy()', () async {
    AdManager.debugAdapterFactory = (_) => _ThrowsAfterInitAdapter();
    final slow = _SlowAdapter();
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return built == 1 ? slow : _OkAdapter();
    };

    bool? parkedResult;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => parkedResult = success,
    );

    // The host gives up on the whole SDK while the first init is still blocked.
    await AdManager().destroy();
    expect(parkedResult, isFalse,
        reason: 'a teardown mid-init must not leave a parked caller waiting on '
            'a callback nothing will ever fire');

    slow.gate.complete();
    await first;
  });

  test('the iOS ATT-order warning really reaches the host log', () async {
    // Round-25 QC round 4 (`codex`, `agy`): deleting the
    // `SafeLogger.critical(_tag, attWarning)` line left all 16 tests green,
    // because the check read `dart:io`'s `Platform.isIOS` — false on the macOS
    // host running `flutter test`, so the warning was always null and the call
    // site unreachable. Reading Flutter's `defaultTargetPlatform` instead makes
    // it drivable from a test, which is the whole point: this warning is the
    // only thing telling an iOS host it called `initialize()` before
    // `requestAtt()`, an ordering that quietly costs attribution revenue.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    final criticals = <String>[];
    await AdManager().initialize(
      config: AdConfig(
        provider: AdProvider.admob,
        admob: _admobIds,
        safety: const AdSafetyParams(dryRun: true),
        firstInstallVipGrace: FirstInstallVipGrace.disabled,
        // Silenced logging AND a tag filter that excludes the SDK: after
        // round 4 neither can hide a `critical`.
        logLevel: AdLogLevel.none,
        logTagFilter: const ['SomeoneElse'],
        onLog: (level, tag, msg) {
          if (level == AdLogLevel.error) criticals.add(msg);
        },
      ),
      onComplete: (_, __) {},
    );

    expect(criticals.where((m) => m.contains('requestAtt')), isNotEmpty,
        reason: 'an iOS host that never called requestAtt() has to be told, '
            'and no logger configuration may hide it');
  });

  test('destroy() leaves nothing listening to the torn-down adapter', () async {
    // Round-25 QC round 4 (`agy`) — deleting
    // `old.appOpenSlot.state.removeListener(_onAppOpenStateChange)` from
    // `_disposeAdapter()` left every test green: the detach had no observable
    // effect, even though a listener surviving on a manager that has been torn
    // down keeps the dead manager reacting to slot changes and keeps the
    // adapter reachable from the notifier. `AdSlot.debugHasStateListeners`
    // makes it observable.
    //
    // Driven through a SUCCESSFUL init + `destroy()` rather than a failed init,
    // and that is not a convenience: `_scheduleFirstSecondaryLoad()` (which
    // attaches that listener) runs *after* `onComplete(true)`, so on the
    // failure path there is no app-open listener to detach in the first place.
    // Asserting it there would have been asserting nothing — the trap this
    // test was rewritten to avoid.
    final adapter = _OkAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;

    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(AdManager().isInitialised, isTrue);
    expect(adapter.appOpenSlot.debugHasStateListeners, isTrue,
        reason: 'baseline — the SDK really did attach listeners to this slot');

    await AdManager().destroy();

    expect(adapter.appOpenSlot.debugHasStateListeners, isFalse,
        reason: 'the app-open state listener must go with the adapter');
    expect(adapter.interstitialSlot.debugHasStateListeners, isFalse);
    expect(adapter.rewardedSlot.debugHasStateListeners, isFalse);
  });

  test('a failed init stops tracking later consent changes', () async {
    // Round-25 QC round 4 (`agy`) — deleting `_detachConsentListener()` from
    // the post-success failure branch left every test green. A leaked listener
    // there keeps a torn-down AdManager reacting to every later consent change:
    // it rewrites its own `consent` state and (with a live adapter in a real
    // app) pushes consent into a provider the host was told is gone.
    //
    // `_ConsentApplyThrowsAdapter` exists so the listener is actually attached
    // when the failure hits — see its comment.
    AdManager.debugAdapterFactory = (_) => _ConsentApplyThrowsAdapter();
    bool? reported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => reported = success,
    );
    expect(reported, isFalse);
    expect(AdManager().isInitialised, isFalse);
    expect(AdManager().consent.doNotSell, isFalse, reason: 'baseline');

    // A privacy screen, a CCPA opt-out — anything writing consent after the
    // SDK has already reported failure.
    await ConsentManager.instance.set(const ConsentSettings(
      hasUserConsent: true,
      doNotSell: true,
      hasBeenAsked: true,
    ));

    expect(AdManager().consent.doNotSell, isFalse,
        reason: 'a manager that told the host init failed must not still be '
            'tracking consent changes');
  });


  test('destroy() during an in-flight init keeps the SDK down', () async {
    // Round-25 QC round 5 (`codex`, BLOCKER). `destroy()` tore everything down
    // and told the parked callers `false`, but did not invalidate the attempt
    // still sitting inside native init. When that attempt resumed it installed
    // `_config`/`_adapter`, re-armed the retry timer and the connectivity
    // watch, and reported `onComplete(true)` — the SDK came back to life
    // *after* teardown, and the caller `destroy()` had just told `false` could
    // then read `isInitialised == true`. `_initGen` now settles the race.
    final slow = _SlowAdapter();
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return slow;
    };

    bool? firstResult;
    String? firstGaid;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, gaid) {
        firstResult = success;
        firstGaid = gaid;
      },
    );
    // Wait for the attempt to actually reach native init — the pre-adapter
    // bootstrap (GAID, VIP load with its own storage retry, consent) has its
    // own aborts now, and this test is about the adapter window specifically.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (built == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(built, 1, reason: 'baseline — the attempt reached native init');

    await AdManager().destroy();
    expect(AdManager().isInitialised, isFalse, reason: 'baseline');

    // Native init finally comes back, long after the host gave up.
    slow.gate.complete();
    await first;
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().isInitialised, isFalse,
        reason: 'an attempt that lost the race to destroy() must not install '
            'itself into the torn-down SDK');
    expect(firstResult, isFalse,
        reason: 'and must not claim success either — the SDK is down');
    expect(slow.disposeCalls, 1,
        reason: 'the adapter it had already built must be released, not '
            'orphaned with its native listeners still wired (round-6 `agy` '
            'mutation: deleting that dispose kept every test green)');
    expect(firstGaid, isNotNull,
        reason: 'the abandoned report still carries both halves of the '
            'onComplete contract — the GAID itself is legitimately empty here '
            'because destroy() clears it; the GAID *value* is pinned on the '
            'supersede path instead (see the loser/winner test below)');
  });

  test('a parked caller that re-inits from inside the drain is answered too',
      () async {
    // Round-25 QC round 5 (`codex`, MAJOR). The success drain runs while
    // `_isInitializing` is still `true`, so a parked callback calling
    // `initialize()` again — the obvious host reaction — was parked into the
    // queue the drain had just cleared, and nothing drained it afterwards.
    // That caller got no `onComplete` and no event: the exact bug the queue
    // exists to fix, one level of recursion down.
    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory = (_) => slow;

    bool? reentrantResult;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {
        // Fired from inside `_drainQueuedInitCallbacks`.
        unawaited(AdManager().initialize(
          config: _okConfig,
          onComplete: (success, _) => reentrantResult = success,
        ));
      },
    );

    slow.gate.complete();
    await first;

    expect(reentrantResult, isNotNull,
        reason: 'a caller parked by a re-entrant initialize() during the drain '
            'must still be told the result');
  });

  test('a parked caller is handed the real GAID, not an empty string',
      () async {
    // Round-25 QC round 5 (`codex`) — mutating `cb(success, _currentDeviceGAID)`
    // to `cb(success, '')` kept every test in this file green: nothing checked
    // that the second half of the `onComplete(bool, String)` contract survives
    // the parking. Hosts use that GAID (VIP-by-device whitelists, support
    // tickets), so a parked caller silently getting `''` is a real difference.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('advertising_id'),
            (call) async => 'GAID-FOR-THE-PARKED-CALLER');
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('advertising_id'), null));

    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory = (_) => slow;

    String? parkedGaid;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, gaid) => parkedGaid = gaid,
    );

    slow.gate.complete();
    await first;

    expect(parkedGaid, 'GAID-FOR-THE-PARKED-CALLER');
  });


  test('destroy() inside the consent window is not answered with success',
      () async {
    // Round-25 QC round 5 (`codex`, BLOCKER — second window). `_config` and
    // `_adapter` are installed before consent is applied to the providers, and
    // both that and the TCF read are awaited, so a `destroy()` landing there
    // used to be followed by `onComplete(true)`: the host was told the SDK was
    // up while `isInitialised` had already gone false and the adapter was
    // disposed. Any ad call it then made was a no-op it had no way to predict.
    final adapter = _DestroyOnConsentAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;

    bool? reported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => reported = success,
    );
    await Future<void>.delayed(Duration.zero);

    expect(adapter.destroyed, isTrue, reason: 'baseline — destroy() did run');
    expect(reported, isFalse,
        reason: 'an init torn down mid-consent must not claim success');
    expect(AdManager().isInitialised, isFalse);
  });


  test('a terminal init failure drains the parked callers too', () async {
    // Round-25 QC round 5 (`agy`) — deleting `_drainQueuedInitCallbacks(false)`
    // from `_reportInitFailure` left every test green: the failure drain was
    // only ever exercised through `destroy()`. This is the ordinary case — the
    // in-flight attempt fails terminally on its own — and it is the one where
    // a stranded caller hurts most, because the host is in its splash waiting
    // on exactly that callback.
    final slow = _SlowThrowsAfterInitAdapter();
    AdManager.debugAdapterFactory = (_) => slow;

    bool? firstResult;
    bool? parkedResult;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => firstResult = success,
    );
    await Future<void>.delayed(Duration.zero);
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => parkedResult = success,
    );

    slow.gate.complete();
    await first;

    expect(firstResult, isFalse, reason: 'baseline — the attempt did fail');
    expect(parkedResult, isFalse,
        reason: 'the parked caller must hear the failure, not silence');
    expect(AdManager().debugInitRetryScheduled, isFalse,
        reason: 'a post-success throw is terminal — no retry loop');
  });

  test('a parked callback that throws cannot strand the next one', () async {
    // Round-25 QC round 5 (`claude`) — the `try/catch` around each parked
    // callback was unpinned. Host callbacks throw (a splash that navigates on
    // a disposed context is the classic one), and without the guard the first
    // throwing parked caller took the rest of the drain down with it — and,
    // from `destroy()`, the rest of the teardown as well. Round 4 fixed exactly
    // this for the primary caller; it must hold for the parked ones too.
    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory = (_) => slow;

    var secondParkedRan = false;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) => throw StateError('host splash blew up'),
    );
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) => secondParkedRan = true,
    );

    slow.gate.complete();
    await first;

    expect(secondParkedRan, isTrue,
        reason: 'one throwing host callback must not cost the next parked '
            'caller its result');
    expect(AdManager().isInitialised, isTrue,
        reason: 'and must not damage the init it was reporting on');
  });


  test('a superseded attempt cannot resurrect VIP state after destroy()',
      () async {
    // Round-25 QC round 6 (`codex` MAJOR, `agy` MAJOR) — the abort checks only
    // covered the adapter windows, but `initialize()` awaits well before that:
    // the GAID fetch, `VipManager.load()` (secure storage, with its own retry),
    // the consent bootstrap. A `destroy()` landing in there was followed by the
    // attempt installing a live `VipManager` with `vipReady == true` and a
    // listener attached — VIP state resurrected on a torn-down SDK, which for a
    // VIP user means ads suppressed by a session the host thinks is gone.
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    bool? reported;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => reported = success,
    );
    // No gate here on purpose: `destroy()` is called in the very first
    // microtask gap, which lands inside the pre-adapter bootstrap.
    await AdManager().destroy();
    await first;
    await Future<void>.delayed(Duration.zero);

    expect(reported, isFalse);
    expect(AdManager().isInitialised, isFalse);
    expect(AdManager().vip, isNull,
        reason: 'a torn-down SDK must not end up holding the VipManager the '
            'losing attempt had just loaded');
  });

  test('the 33rd parked caller is answered instead of parked', () async {
    // Round-25 QC round 6 (`agy` mutation) — deleting the 32-caller cap kept
    // every test green. The cap is what stops a host looping `initialize()`
    // (a retry timer, a rebuild loop) from holding an unbounded list of
    // closures alive for the whole retry budget, and the overflow caller must
    // still be told something rather than parked forever.
    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory = (_) => slow;

    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);

    final answers = <int, bool>{};
    for (var i = 0; i < 33; i++) {
      await AdManager().initialize(
        config: _okConfig,
        onComplete: (success, _) => answers[i] = success,
      );
    }

    expect(answers.length, 1,
        reason: 'only the overflow caller (the 33rd) is answered early');
    expect(answers[32], isFalse,
        reason: 'and it is told false rather than parked past the cap');

    slow.gate.complete();
    await first;
    expect(answers.length, 33, reason: 'the parked 32 still get their result');
    expect(answers.values.where((v) => v).length, 32);
  });

  test('initialize() called from inside a drain is answered on the spot',
      () async {
    // Round-25 QC round 6 (`codex` MAJOR, `agy` mutation) — round 5 drained in
    // a loop capped at 8 passes and dropped whatever was parked past the cap,
    // which is the "told nothing at all" outcome all over again. There is no
    // cap now: during a drain the result is already known, so a re-entrant
    // caller is answered synchronously by the duplicate guard and the queue
    // cannot grow from inside the drain at all. Asserting *synchronously* is
    // what separates the two designs — the loop would have answered it too,
    // but only on its next pass.
    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory = (_) => slow;

    var answeredWithoutYielding = false;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {
        var inner = false;
        unawaited(AdManager().initialize(
          config: _okConfig,
          onComplete: (_, __) => inner = true,
        ));
        // No await in between: with the round-5 design `inner` is still false
        // here, and the caller waits for the next drain pass to hear anything.
        answeredWithoutYielding = inner;
      },
    );

    slow.gate.complete();
    await first;

    expect(answeredWithoutYielding, isTrue,
        reason: 'a caller arriving during the drain must be handed the result '
            'immediately, not queued behind the drain that is running');
  });


  test('a superseded attempt that fails does not arm a retry on a dead SDK',
      () async {
    // Round-25 QC round 6 (all three reviewers, BLOCKER). The abort check only
    // guarded the *success* path, so an attempt whose native init came back
    // `false` after `destroy()` still went through the ordinary failure branch:
    // it armed a 5-second retry timer that then called `initialize()` on the
    // torn-down SDK, and it fired `BoolEvent(false)`. `SimpleEventBus` replays
    // its latest event, so that loser's `false` is what a late-subscribing
    // splash would have been handed even after a later attempt had succeeded.
    final slow = _SlowFailingAdapter();
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return slow;
    };

    bool? reported;
    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => reported = success,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (built == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(built, 1, reason: 'baseline — the attempt reached native init');

    await AdManager().destroy();
    slow.gate.complete();
    await first;
    await Future<void>.delayed(Duration.zero);

    expect(reported, isFalse);
    expect(AdManager().debugInitRetryScheduled, isFalse,
        reason: 'a torn-down SDK must not have a retry timer ticking against '
            'it — that timer calls initialize() again five seconds later');
    expect(AdManager().isInitialised, isFalse);
  });

  test('a superseded attempt that throws cannot kill the live session',
      () async {
    // Round-25 QC round 6 (`claude`, BLOCKER, reproduced live). The outer
    // `catch` decided "my adapter came up, tear it down" by reading the shared
    // `_adapter`/`_config` fields, with no check that they still belonged to
    // this attempt. So a stale attempt that threw *after a different attempt
    // had already won* disposed the winner's live adapter, flipped
    // `isInitialised` back to false and fired `BoolEvent(false)` for a session
    // that never failed and was never torn down by its host. The loser killing
    // the winner — strictly worse than the round-5 bug it grew out of.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('advertising_id'),
            (call) async => 'GAID-OF-THE-WINNER');
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('advertising_id'), null));
    final loser = _SlowThrowingInitAdapter();
    final winner = _OkAdapter();
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return built == 1 ? loser : winner;
    };

    bool? loserResult;
    String? loserGaid;
    final stale = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, gaid) {
        loserResult = success;
        loserGaid = gaid;
      },
    );
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (built == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // The host gives up, then starts over. The second attempt wins outright.
    await AdManager().destroy();
    bool? winnerResult;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => winnerResult = success,
    );
    expect(winnerResult, isTrue, reason: 'baseline — the second attempt won');
    expect(AdManager().isInitialised, isTrue);

    // Only now does the abandoned attempt's native init come back, throwing.
    loser.gate.complete();
    await stale;
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().isInitialised, isTrue,
        reason: 'the winning session must survive the loser\'s throw');
    expect(winner.disposeCalls, 0,
        reason: "the loser must not dispose the winner's live adapter");
    expect(loserResult, isFalse,
        reason: 'the loser still reports its own failure to its own caller');
    expect(loserGaid, 'GAID-OF-THE-WINNER',
        reason: 'round-6 `agy` mutation: replacing the GAID in '
            '_reportAbandonedInit with an empty string kept every test green — '
            'the GAID is device-level, so the live one is the honest answer');
  });


  test('a caller arriving during destroy()\'s teardown waits, then gets a live '
      'session', () async {
    // Round-25 QC round 7 (`codex` MAJOR, `agy` MAJOR). `destroy()` awaits
    // half-way through its teardown (event stream close, adapter dispose) and
    // everything after those awaits assumes no new session exists. A host that
    // called `initialize()` in that window had its session built and then
    // gutted by the rest of the teardown: adapter disposed, and its lifecycle
    // observer removed (because `_ensureObserverAdded` saw the old one still
    // registered and did nothing), which silently kills App Open on resume for
    // the rest of the process. `initialize()` now waits the teardown out.
    //
    // Round 6 pinned the *previous* behaviour here — the caller parked and was
    // answered `false` by the abandoned attempt. Waiting and getting a real
    // session is what the host asked for, in the order it asked.
    final slow = _SlowAdapter();
    final fresh = _OkAdapter();
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return built == 1 ? slow : fresh;
    };

    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (built == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(built, 1, reason: 'baseline — the first attempt reached native init');

    // Not awaited on purpose: this returns at `destroy()`'s first await, which
    // is the window the new session lands in.
    final teardown = AdManager().destroy();
    expect(AdManager().debugDestroyInFlight, isTrue,
        reason: 'baseline — the teardown really is mid-flight here');
    bool? second;
    final reinit = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => second = success,
    );
    expect(second, isNull,
        reason: 'baseline — the new session has not been built yet');

    await teardown;
    await reinit;

    expect(second, isTrue,
        reason: 'the caller that waited out the teardown gets a working '
            'session, not a gutted one');
    expect(AdManager().isInitialised, isTrue);
    expect(fresh.disposeCalls, 0,
        reason: "the tail of destroy() must not dispose the new session's "
            'adapter');
    expect(AdManager().debugLifecycleObserverAttached, isTrue,
        reason: 'and must not take the new session\'s lifecycle observer with '
            'it — `_ensureObserverAdded()` saw the old session\'s observer '
            'still registered and did nothing, so the tail of destroy() '
            'removing it leaves App Open on resume dead for the rest of the '
            'process, silently');

    // Only now does the abandoned first attempt's native init come back.
    slow.gate.complete();
    await first;
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().isInitialised, isTrue,
        reason: 'and the abandoned attempt must not take it down either');
    expect(fresh.disposeCalls, 0);
    expect(slow.disposeCalls, 1,
        reason: 'the abandoned attempt still releases what it built');
  });

  test('a UMP result from a torn-down session cannot open the live gate',
      () async {
    // Round-25 QC round 7 (`codex`, BLOCKER). The auto-UMP flow is
    // fire-and-forget, so its result can land minutes later — after a
    // `destroy()` and a fresh `initialize()`. It used to write `canRequestAds`
    // unconditionally, so a dead session's answer opened the live session's ad
    // gate. The gate is the compliance surface: the live session may be an
    // under-age-tagged config deliberately holding it shut until its own flow
    // answers. Bound to `_consentSessionEpoch`, the same epoch the
    // privacy-options form has been bound to since round 13.
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    // A UMP round trip captured this session's epoch.
    final staleSession = AdManager().debugConsentSessionEpoch;

    await AdManager().destroy();
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    AdManager().debugCanRequestAds = false;

    await AdManager().debugApplyUmpConsentResult(
      const UmpConsentResult(
        status: ConsentStatus.obtained,
        canRequestAds: true,
      ),
      session: staleSession,
    );

    expect(AdManager().canRequestAds, isFalse,
        reason: 'the dead session\'s UMP answer must not open the live '
            "session's ad gate");

    // The live session's own result still applies, obviously.
    await AdManager().debugApplyUmpConsentResult(
      const UmpConsentResult(
        status: ConsentStatus.obtained,
        canRequestAds: true,
      ),
      session: AdManager().debugConsentSessionEpoch,
    );
    expect(AdManager().canRequestAds, isTrue);
  });

  test('a nested drain restores the outer drain\'s result instead of nulling it',
      () async {
    // Round-25 QC round 7 (`agy`, MAJOR). The drain publishes its result in
    // `_drainingInitResult` so a callback that re-enters `initialize()` is
    // answered on the spot instead of parking behind a queue that has already
    // been drained. A queued callback is free to call `destroy()`, which drains
    // the queue itself — and that nested drain's `finally` used to clear the
    // field outright rather than restoring it, so the rest of the outer drain
    // ran as if no drain were in progress at all.
    //
    // Asserted on the field directly, and honestly: `agy`'s scenario turned out
    // NOT to be reachable — a caller cannot park while a drain is running (it
    // is answered on the spot instead), and the drain copies-and-clears the
    // queue, so the nested drain returns at its own `isEmpty` early exit before
    // it can touch the field at all. This test pins the invariant the field is
    // supposed to hold (set for the whole outer drain, null once no drain is
    // running); the save/restore itself is defensive, and deleting it keeps the
    // suite green. Left in because it is two lines and it is the difference
    // between the invariant holding by construction and holding by luck.
    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory = (_) => slow;

    final first = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    // Parked caller #1 parks another caller (so the nested drain below has
    // something to drain) and then tears the SDK down from inside the drain.
    AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {
        AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
        unawaited(AdManager().destroy());
      },
    );
    // Parked caller #2 runs after that nested drain has come and gone.
    bool? drainingSeenByTheNextCallback = false;
    AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) =>
          drainingSeenByTheNextCallback = AdManager().debugDrainingInitResult,
    );

    slow.gate.complete();
    await first;
    await Future<void>.delayed(Duration.zero);

    expect(drainingSeenByTheNextCallback, isTrue,
        reason: 'the outer drain is still running and still handing out '
            '`true` — a nested drain must put back what it found');
    expect(AdManager().debugDrainingInitResult, isNull,
        reason: 'and once no drain is running the field is null again, or '
            'every later initialize() gets answered with a stale result');
  });


  test('a stale attempt cannot hand a live init\'s busy flag back to false',
      () async {
    // Round-25 QC round 7 (`claude` and `agy`, both MAJOR, both by mutation).
    // `initialize()`'s outer `finally` releases `_isInitializing` only for the
    // generation that still owns it. Round 6 had that guard but nothing pinned
    // it: the loser/winner test awaited the winner to completion before
    // releasing the loser, so the flag was already `false` either way. Here the
    // winner is still mid-flight when the loser throws — which is the whole
    // point of the guard.
    final loser = _SlowThrowingInitAdapter();
    final winner = _SlowAdapter();
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return built == 1 ? loser : winner;
    };

    final stale = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (built == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await AdManager().destroy();

    bool? winnerResult;
    final live = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => winnerResult = success,
    );
    while (built < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(built, 2, reason: 'baseline — the winner reached native init');
    expect(winnerResult, isNull, reason: 'baseline — and is still in flight');

    // The abandoned attempt throws and runs its `finally` while the winner is
    // still waiting on native init.
    loser.gate.complete();
    await stale;
    await Future<void>.delayed(Duration.zero);

    // A third caller arriving now must be parked behind the winner, not turned
    // loose to build a session of its own.
    bool? thirdResult;
    final third = AdManager().initialize(
      config: _okConfig,
      onComplete: (success, _) => thirdResult = success,
    );
    await Future<void>.delayed(Duration.zero);
    expect(built, 2,
        reason: 'the stale attempt released a busy flag that was no longer '
            "its own, so a third caller slipped past the duplicate guard and "
            'built a second live adapter');
    expect(thirdResult, isNull, reason: 'it is parked, not answered');

    winner.gate.complete();
    await Future.wait<void>([live, third]);

    expect(winnerResult, isTrue,
        reason: 'the winner owns the session and reports its own success');
    expect(thirdResult, isTrue,
        reason: 'and the parked caller is told the winner\'s result');
    expect(AdManager().isInitialised, isTrue);
  });

  test('a late event-bus subscriber hears the winner, never the loser',
      () async {
    // Round-25 QC round 7 (`claude`, MAJOR, by mutation). `_reportAbandonedInit`
    // deliberately fires no `BoolEvent`: the bus REPLAYS its most recent event
    // to whoever subscribes later, so a loser's `false` landing after the
    // winner's `true` tells a late-subscribing splash that init failed when it
    // did not — the documented integration contract (README step 3) has the
    // splash react to that event. Round 6 relied on a comment; mutating it to
    // fire `BoolEvent(false)` kept all 33 tests green.
    final loser = _SlowThrowingInitAdapter();
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return built == 1 ? loser : _OkAdapter();
    };

    final stale = AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (built == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await AdManager().destroy();
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );

    // The loser's native init only now comes back, throwing.
    loser.gate.complete();
    await stale;
    await Future<void>.delayed(Duration.zero);

    // A splash that subscribes this late gets the replayed event.
    bool? replayed;
    void listener(BoolEvent e) => replayed = e.value;
    SimpleEventBus().listen(listener);
    addTearDown(() => SimpleEventBus().remove(listener));

    expect(replayed, isTrue,
        reason: 'the winning session is up, so a late subscriber must hear '
            'true — an abandoned attempt must not fire an event at all');
  });


  test('a second destroy() waits for the first and then does nothing at all',
      () async {
    // Round-25 QC round 8 (`codex` and `agy`, independently, MAJOR) — the
    // second caller awaited the in-flight teardown and then fell through into
    // a complete second teardown, which the log line right above it claimed it
    // was avoiding. Two observable costs: every subscribed widget was told to
    // rebuild twice (`initRevision`), and the redundant teardown could land on
    // a session the host had started in the meantime.
    final adapter = _SlowDisposeAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});

    final revisionBefore = AdManager().initRevision.value;
    final first = AdManager().destroy();
    await Future<void>.delayed(Duration.zero);
    final second = AdManager().destroy();
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().debugDestroyInFlight, isTrue,
        reason: 'the first teardown is parked in the adapter dispose');

    adapter.gate.complete();
    await first;
    // Let the second caller resume from its `await pending`.
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().debugDestroyInFlight, isFalse,
        reason: 'the second caller must return, not start a fresh teardown '
            'that can gut a session the host started after the first one '
            'finished');
    await second;
    expect(AdManager().initRevision.value, revisionBefore + 1,
        reason: 'one teardown happened, so subscribed widgets rebuild once');
    expect(adapter.disposeCalls, 1);
  });

  test(
      'a host-initiated initialize() adopts the pending retry\'s stranded '
      'caller instead of dropping it', () async {
    // Round-25 QC round 8 (`agy`, MAJOR) — a failed native init arms a 5s
    // retry timer that *holds the caller's `onComplete`*, so `initialize()`
    // returns without answering that caller. A fresh host-initiated
    // `initialize()` (the splash's own "Retry" button) cancelled that timer
    // outright, and cancelling a Timer throws its closure away — the first
    // caller was then never answered at all, `true` or `false`. A splash
    // awaiting it sat there until its hard-cap timer fired.
    var built = 0;
    AdManager.debugAdapterFactory = (_) {
      built++;
      return built == 1 ? _FailingAdapter() : _OkAdapter();
    };

    var firstCalls = 0;
    bool? firstReported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, __) {
        firstCalls++;
        firstReported = success;
      },
    );

    expect(firstCalls, 0,
        reason: 'the retry owns the answer for now — this is the existing, '
            'deliberate behaviour the bug hid behind');
    expect(AdManager().debugInitRetryScheduled, isTrue);
    expect(AdManager().debugPendingRetryCallback, isTrue);

    // The user taps "Retry" before the 5s timer fires.
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (_, __) {},
    );

    expect(AdManager().debugInitRetryScheduled, isFalse,
        reason: 'a fresh host call cancels the pending retry');
    expect(firstCalls, 1,
        reason: 'the caller the cancelled retry was holding gets answered by '
            'the attempt that replaced it');
    expect(firstReported, isTrue,
        reason: 'and answered with the truth: the SDK is up now');
    expect(AdManager().debugPendingRetryCallback, isFalse);
  });

  test('destroy() answers the pending retry\'s stranded caller false',
      () async {
    // Same MAJOR, the teardown half. `destroy()` drains
    // `_queuedInitCallbacks`, but a pending retry's caller is never in that
    // queue — it lives in the Timer closure that `destroy()` cancels.
    AdManager.debugAdapterFactory = (_) => _FailingAdapter();
    var calls = 0;
    bool? reported;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, __) {
        calls++;
        reported = success;
      },
    );

    expect(calls, 0);
    expect(AdManager().debugPendingRetryCallback, isTrue);

    await AdManager().destroy();

    expect(calls, 1,
        reason: 'the SDK is going down, so nobody else will ever answer this '
            'caller — leaving it waiting hangs the splash');
    expect(reported, isFalse);
    expect(AdManager().debugPendingRetryCallback, isFalse);
  });


  test('an init retry that fires during destroy() cannot resurrect the SDK',
      () async {
    // Round-25 QC round 9 (`codex`, BLOCKER) — and the reproduction is the
    // finding's real value. My own post-round-8 audit had spotted this window
    // and written it off as "a few microseconds wide, no fake-clock seam, not
    // pinnable". Wrong: a *paused* subscriber to `AdManager().events` holds
    // `_eventStream.close()` open for as long as the test likes, which parks
    // the teardown past the whole 5s retry backoff. With the retry cancel
    // sitting where it used to (after `_eventStream.close()` and
    // `_disposeAdapter()`), the timer fires inside that window, its
    // `initialize()` waits out `_destroyInFlight` (round 7) and only then takes
    // its generation — so `_initGen` cannot supersede it and it rebuilds a
    // whole session, adapter, timers and connectivity watch included, straight
    // after the host's `await destroy()` returned. Cancelling at the top of
    // `_destroy()`, before its first await, is what this pins.
    var built = 0;
    AdManager.debugAdapterFactory =
        (_) => ++built == 1 ? _FailingAdapter() : _OkAdapter();
    bool? result;
    var calls = 0;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (success, __) {
        calls++;
        result = success;
      },
    );

    expect(AdManager().debugPendingRetryCallback, isTrue,
        reason: 'native init failed, so a retry owns this caller');

    final sub = AdManager().events.listen((_) {});
    sub.pause();
    final teardown = AdManager().destroy();
    // Round-25 QC round 11 — the hold is now BOUNDED (`_eventStream.close()`
    // times out after 2s, so one paused listener can no longer hang a teardown
    // forever). The backoff is shortened from the seam instead, which is what
    // this test was ever really about: a retry firing while a teardown is in
    // flight, not the literal 5 seconds.
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(AdManager().debugDestroyInFlight, isTrue,
        reason: 'the paused subscriber is holding the teardown open, and the '
            'shortened retry backoff has now elapsed inside that window');

    sub.resume();
    await teardown;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await sub.cancel();

    expect(built, 1,
        reason: 'the retry was killed before the teardown\'s first await, so '
            'no second adapter was ever built');
    expect(calls, 1, reason: 'answered exactly once');
    expect(result, isFalse,
        reason: 'and answered by the teardown, with the truth');
    expect(AdManager().isInitialised, isFalse,
        reason: 'the host awaited destroy() — the SDK must stay down, not come '
            'back to life and start requesting ads again');
  });

  // Round-25 QC round 10 (`claude`, MINOR — a coverage gap, not a live bug).
  // The reviewer deleted `_pendingRetryOnComplete = null;` from inside the
  // retry timer's own callback and the whole 1181-test suite stayed green: the
  // code was right, nothing pinned it. This is that pin. Once the timer has
  // fired, the retry attempt itself owns the host callback and will answer it
  // when it is superseded — so the field MUST be clear, or `destroy()` finds a
  // live callback there, answers it `false`, and the abandoned attempt answers
  // a second time. A host doing `Navigator.pop()` in `onComplete` pops twice.
  test('a retry that already fired cannot have its caller answered twice',
      () async {
    var built = 0;
    final slow = _SlowAdapter();
    AdManager.debugAdapterFactory =
        (_) => ++built == 1 ? _FailingAdapter() : slow;

    var calls = 0;
    bool? result;
    unawaited(AdManager().initialize(
      config: _okConfig,
      isRelease: false,
      onComplete: (ok, _) {
        calls++;
        result = ok;
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(AdManager().debugInitRetryScheduled, isTrue,
        reason: 'the failing native init must have armed the 5s retry');
    expect(AdManager().debugPendingRetryCallback, isTrue,
        reason: 'while the timer is pending, IT owns the host callback');

    // Past the 5s backoff: the timer fires OUTSIDE any teardown, hands the
    // callback to its own attempt, and that attempt parks on the gate below.
    // Round-25 QC round 11 (`codex`, MINOR) — poll, never a fixed sleep. Under
    // load the first attempt's own VIP/UMP work ate into a flat 5.2s wait and
    // the retry had not fired yet, so the test failed on an unmutated tree.
    await _pumpUntil(() => built == 2);
    expect(built, 2, reason: 'the retry attempt must have started');
    expect(AdManager().debugPendingRetryCallback, isFalse,
        reason: 'the fired timer must have released the callback to the '
            'attempt it started — leaving it set makes destroy() answer a '
            'callback the attempt is also going to answer');
    expect(calls, 0, reason: 'nobody has answered the host yet');

    // Host tears down while the retry attempt is still inside native init.
    await AdManager().destroy();
    slow.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(calls, 1,
        reason: 'exactly one answer: the superseded retry attempt reports its '
            'own failure. Two answers means the teardown answered a callback '
            'that was no longer its to answer');
    expect(result, isFalse);
    expect(AdManager().isInitialised, isFalse);
  });

  // Round-25 QC round 11 (`codex`, BLOCKER). A host subscription to the public
  // `events` stream may legally be paused — a route transition, backpressure,
  // a listener the framework parked. A paused subscriber buffers the done
  // event, so `_eventStream.close()` does not complete until it resumes, and
  // the teardown used to `await` that with no bound. `_destroyInFlight` is
  // already published by then, so every later `initialize()` parks behind it:
  // one paused listener, and the SDK is bricked for the rest of the process.
  test('a paused events subscriber cannot hang destroy() forever', () async {
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
    expect(AdManager().isInitialised, isTrue);

    final sub = AdManager().events.listen((_) {});
    sub.pause();

    // Never resumed. The teardown must finish anyway, on its own bound.
    await AdManager().destroy().timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('destroy() never returned while a subscriber was '
          'paused — an unbounded await on the event-stream close lets one '
          'paused listener brick the SDK permanently'),
    );

    expect(AdManager().isInitialised, isFalse,
        reason: 'the teardown ran to completion, not just up to the close');
    expect(AdManager().debugDestroyInFlight, isFalse,
        reason: 'and released the gate, so a later initialize() is not stuck');

    // And prove the SDK is genuinely reusable afterwards, which is the thing
    // the hang actually cost the host.
    var reinit = false;
    await AdManager()
        .initialize(config: _okConfig, onComplete: (ok, __) => reinit = ok);
    expect(reinit, isTrue);
    expect(AdManager().isInitialised, isTrue);

    sub.resume();
    await sub.cancel();
  });

  // Round-25 QC round 11 (`codex`, MAJOR). The lifecycle observer used to be
  // removed at the very END of `_destroy()`. Across the teardown's awaits
  // `_adapter` and `_config` are untouched, so every guard on the resume path
  // (`identical(_adapter, ad)`, `isInitialised`) still passes — a user coming
  // back to the app mid-teardown could be shown an App Open ad on top of an
  // SDK being dismantled, and the native call landed on an adapter about to be
  // disposed. Detaching first is what makes the framework unable to reach us
  // at all, which is the only guard that does not depend on field ordering.
  test('the lifecycle observer is detached before the teardown starts awaiting',
      () async {
    final adapter = _SlowDisposeAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
    expect(AdManager().debugLifecycleObserverAttached, isTrue,
        reason: 'a live SDK listens for app resume');

    final teardown = AdManager().destroy();
    // Parked inside `_disposeAdapter()`, i.e. past the event-stream close and
    // well before the tail of `_destroy()` where the detach used to live.
    await _pumpUntil(() => AdManager().debugDestroyInFlight);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(AdManager().debugLifecycleObserverAttached, isFalse,
        reason: 'the teardown is mid-flight and holding: the framework must '
            'already be unable to deliver a resume, or an App Open ad can be '
            'shown on top of an SDK being torn down');

    adapter.gate.complete();
    await teardown;
    expect(AdManager().debugLifecycleObserverAttached, isFalse);
    expect(AdManager().isInitialised, isFalse);
  });

  // Round-25 QC round 12 (`codex`, MAJOR). A teardown must stop work already
  // launched, not just stop new events arriving. A resume that landed a moment
  // before `destroy()` has already opened the 500ms ad buffer, and its
  // `onComplete` fires with `_adapter`/`_config` still live — every guard
  // inside it passes and a fullscreen ad is shown on top of an SDK being
  // dismantled. Pinned at the convergence point: while a teardown is in
  // flight, no fullscreen show may start, whatever launched it.
  test('no fullscreen ad can start while a teardown is in flight', () async {
    final adapter = _ShowCountingAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
    // Ready, so a show would really reach the native layer — the whole point:
    // with the guard mutated away, `showAppOpenCalls` becomes 1.
    adapter.appOpenSlot.markReady();
    expect(adapter.appOpenSlot.isReady, isTrue);
    // And the consent gate open, or every show below is refused for "consent
    // not granted (UMP)" long before the guard under test is reached — the
    // second wrong-reason pass this test went through.
    AdManager().debugCanRequestAds = true;

    // The hold has to be a point where `_adapter` is STILL LIVE, or the shows
    // below get skipped for "adapter null" and the test passes for the wrong
    // reason (`_disposeAdapter()` clears the fields before awaiting the native
    // dispose, so parking in there proves nothing). The event-stream close is
    // that point: a paused subscriber holds it for up to its 2s cap while the
    // adapter and config are untouched — exactly the state a resume buffer's
    // `onComplete` sees when it fires during a teardown.
    // A live listener records WHY each show was refused. `onAdDismiss(false)`
    // alone proves nothing — an unloaded slot answers false too, which is how
    // the first draft of this test passed against a mutated guard.
    final reasons = <String>[];
    final watcher = AdManager().events.listen((e) {
      if (e is AdSkipEvent) reasons.add(e.reason);
    });

    final sub = AdManager().events.listen((_) {});
    sub.pause();
    final teardown = AdManager().destroy();
    await _pumpUntil(() => AdManager().debugDestroyInFlight);
    expect(AdManager().isInitialised, isTrue,
        reason: 'the teardown is held at the stream close, so every field a '
            'show path guards on is still live — the guard under test is the '
            'only thing that can stop it');

    // Exactly what the buffer's onComplete does, from outside it: a show call
    // arriving while the teardown holds.
    var dismissed = true;
    await AdManager().showAppOpenAd(onAdDismiss: (d) => dismissed = d);
    var interstitialShown = true;
    await AdManager().showInterstitial(onDoneFlow: (s) => interstitialShown = s);
    var earned = true;
    await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);

    expect(dismissed, isFalse,
        reason: 'an App Open ad must not be shown during a teardown — the '
            'native call would land on an adapter about to be disposed, and a '
            'user sees an ad the host already tore the SDK down to stop');
    expect(interstitialShown, isFalse);
    expect(earned, isFalse);
    expect(adapter.showAppOpenCalls, 0,
        reason: 'the adapter was never asked to show anything. `dismissed == '
            'false` on its own proves nothing — an unloaded slot answers false '
            'too, which is how the first draft of this test passed against a '
            'mutated guard. Skip reasons seen: $reasons');
    sub.resume();
    await teardown;
    await sub.cancel();
    await watcher.cancel();
  });

  // Round-25 QC round 12 (`codex`, MINOR). `@visibleForTesting` is an analyzer
  // annotation, so this seam is reachable in release. An empty list used to
  // throw `Invalid argument(s): 0` out of the retry scheduler; the outer catch
  // re-entered the same function, the second throw escaped `initialize()`, and
  // the host's `onComplete` was never called — the one outcome the whole init
  // path is built to make impossible.
  test('an empty retry-delay override still answers the host', () async {
    AdManager.debugInitRetryDelays = const [];
    AdManager.debugAdapterFactory = (_) => _FailingAdapter();

    var calls = 0;
    bool? result;
    await AdManager().initialize(
      config: _okConfig,
      onComplete: (ok, __) {
        calls++;
        result = ok;
      },
    );

    // `initialize()` returning at all is half the assertion: with the empty
    // list the index threw, the outer catch re-entered the scheduler, and the
    // second throw escaped this await.
    expect(AdManager().debugInitRetryScheduled, isTrue,
        reason: 'an empty override falls back to the real schedule rather than '
            'throwing, so the retry is still armed');
    expect(AdManager().debugPendingRetryCallback, isTrue,
        reason: 'and the retry owns the host callback, so the host will be '
            'answered — never dropped on the floor by an escaped exception');
    expect(calls, 0,
        reason: 'not answered YET, by design: the pending retry answers');
    expect(result, isNull);
  });


  // Round-25 QC round 13 (`codex`, MAJOR) — CONTROL for the test below it. The
  // on-demand VIP rewarded path really does reach the native layer when nothing
  // is wrong; without this, "the adapter was never asked" in the next test
  // would prove nothing (rounds 11 and 12 both produced a test that passed for
  // exactly that wrong reason).
  test('the on-demand VIP rewarded path does reach the adapter', () async {
    final adapter = _OnDemandRewardedAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
    AdManager().debugCanRequestAds = true;

    var earned = false;
    final show = AdManager()
        .showRewardedAd(bypassVipGuard: true, onEarnedReward: (e) => earned = e);
    await _pumpUntil(() => adapter.rewardedSlot.isLoading);
    expect(adapter.loadRewardedCalls, 1,
        reason: 'the slot was not preloaded, so the on-demand load must run');

    adapter.rewardedSlot.markReady();
    await show;

    expect(adapter.showRewardedCalls, 1);
    expect(earned, isTrue);
  });

  // Round-25 QC round 13 (`codex`, MAJOR). The teardown check at the head of
  // `showRewardedAd` is not enough: with `bypassVipGuard: true` and an unready
  // slot the method then awaits `_loadRewardedOnDemand` for up to 15 seconds,
  // and the post-load re-check consulted `_fullscreenBusyReason`, which did not
  // know about `_destroyInFlight`. codex's probe watched a rewarded ad play and
  // pay out its reward while the SDK was being dismantled underneath it. The
  // fix folds the teardown into `_fullscreenBusyReason` itself, so this and
  // every other post-await re-check inherits it.
  test('a destroy() landing inside the on-demand rewarded load stops the show',
      () async {
    final adapter = _OnDemandRewardedAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
    AdManager().debugCanRequestAds = true;

    var earned = true;
    final show = AdManager()
        .showRewardedAd(bypassVipGuard: true, onEarnedReward: (e) => earned = e);
    // Parked inside `_loadRewardedOnDemand`, past the entry-level teardown
    // guard — the exact window codex exploited.
    await _pumpUntil(() => adapter.rewardedSlot.isLoading);
    expect(adapter.showRewardedCalls, 0);

    // A paused subscriber holds the teardown at `_eventStream.close()` (capped
    // at 2s since round 11), which is BEFORE `_disposeAdapter()` — so the slots
    // and the adapter are still untouched and the released load below really
    // does complete with `ready`, not with a reset-to-idle that would refuse
    // the show for the wrong reason.
    final sub = AdManager().events.listen((_) {});
    sub.pause();
    final teardown = AdManager().destroy();
    await _pumpUntil(() => AdManager().debugDestroyInFlight);

    adapter.rewardedSlot.markReady();
    await show;

    expect(adapter.showRewardedCalls, 0,
        reason: 'the adapter must never be asked to show a rewarded ad while '
            'the session behind it is being dismantled — the control test '
            'above proves this same sequence reaches it when it may');
    expect(earned, isFalse,
        reason: 'and the host must be told no reward was earned, not handed '
            'one from an ad that played over a dying SDK');

    await sub.cancel();
    await teardown;
  });

  // Round-25 QC round 13 (`codex`, MAJOR) — the convergence guard was
  // bypassable from outside: `AdProviderAdapter` is exported and its show
  // methods are public, so a host could keep `AdManager().adapter`, call
  // `destroy()`, and drive the native layer directly. The public getter now
  // reports nothing while a teardown is in flight.
  test('the public adapter getter hides the adapter during a teardown',
      () async {
    final adapter = _OnDemandRewardedAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
    expect(AdManager().adapter, same(adapter));

    final sub = AdManager().events.listen((_) {});
    sub.pause();
    final teardown = AdManager().destroy();
    await _pumpUntil(() => AdManager().debugDestroyInFlight);

    expect(AdManager().adapter, isNull,
        reason: 'a host fetching the adapter mid-teardown must get nothing to '
            'call — the exported show methods answer to no guard in AdManager');
    expect(AdManager().fullscreenBusy.value, isTrue,
        reason: "and the host's own \"ads busy\" mirror must not claim the "
            'surfaces are free while the teardown runs');

    await sub.cancel();
    await teardown;
    expect(AdManager().fullscreenBusy.value, isFalse,
        reason: 'and it must not stay stuck busy after the teardown ends');
  });


  // Round-25 QC round 13 (`codex`, MINOR) — the debug retry override cannot
  // park the host callback for longer than the real backoff ever would.
  test('an absurdly long retry-delay override is capped, not honoured',
      () async {
    AdManager.debugInitRetryDelays = const [Duration(days: 36500)];
    AdManager.debugLastInitRetryDelay = null;
    final adapter = _FailingAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;

    var calls = 0;
    await AdManager()
        .initialize(config: _okConfig, onComplete: (_, __) => calls++);

    expect(AdManager().debugInitRetryScheduled, isTrue);
    expect(calls, 0, reason: 'a retry is armed, so the host waits (round 8)');
    // Honoured verbatim, `onComplete` would sit in `_pendingRetryOnComplete`
    // for a century with no timeout anywhere to rescue it.
    expect(AdManager.debugLastInitRetryDelay, const Duration(seconds: 30),
        reason: 'a test seam may make the retry faster than production, never '
            'slower — the override must be capped at the longest real backoff');
  });


  // Round-25 QC round 14 (`codex`, MAJOR) — the load-side twin of round 13.
  // A load starting inside a teardown reaches the native SDK and its callback
  // lands on slots about to be disposed. codex's probe expected zero native
  // calls and got 1.
  test('no ad load can start while a teardown is in flight', () async {
    final adapter = _OnDemandRewardedAdapter();
    AdManager.debugAdapterFactory = (_) => adapter;
    await AdManager().initialize(config: _okConfig, onComplete: (_, __) {});
    AdManager().debugCanRequestAds = true;
    // A real connectivity watch answers `false` in a unit-test process, and
    // "skipped — no network" would let a mutated guard pass this test. Seed
    // last-known = connected, then send `isConnected` down its pre-ready
    // branch, which trusts that value instead of the dead detector.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(true);
    adapter.rewardedSlot.reset();
    adapter.loadRewardedCalls = 0;
    // Control: the same call reaches native when nothing is wrong.
    await AdManager().loadRewardedAd();
    expect(adapter.loadRewardedCalls, 1,
        reason: 'control — without this the assertion below would pass for '
            'any number of unrelated reasons');
    adapter.rewardedSlot.reset();

    final sub = AdManager().events.listen((_) {});
    sub.pause();
    final teardown = AdManager().destroy();
    await _pumpUntil(() => AdManager().debugDestroyInFlight);
    expect(AdManager().isInitialised, isTrue,
        reason: 'the teardown is held at the stream close, so `_adapter` is '
            'still live — the guard under test is the only thing that can '
            'stop the load');

    await AdManager().loadRewardedAd();
    await AdManager().loadInterstitial();
    await AdManager().loadAppOpenAd();

    expect(adapter.loadRewardedCalls, 1,
        reason: 'no second native request may be issued during a teardown — '
            'it would be wasted (counted by the network as an unfilled '
            'request) and its callback would land on a disposed slot');

    await sub.cancel();
    await teardown;
  });

  // Round-25 QC round 14 (`codex`, MAJOR, second half) — a load already in
  // flight when `destroy()` starts cannot be recalled by any guard in
  // AdManager. Its callback used to write a disposed ValueNotifier, which
  // throws "was used after being disposed" — a real crash in a host app whose
  // only sin was tearing the SDK down while an ad was loading.
  test('a native callback landing after dispose is dropped, not fatal',
      () async {
    final slot = AdSlot(type: AdSlotType.rewarded);
    slot.beginLoad();
    slot.dispose();
    expect(slot.debugStateDisposed, isTrue);

    // Exactly what a late AdMob/AppLovin callback does.
    expect(slot.markReady, returnsNormally);
    expect(slot.markFailed, returnsNormally);
    expect(slot.markDismissed, returnsNormally);
    expect(slot.markShowFailed, returnsNormally);
    expect(slot.reset, returnsNormally);
    expect(slot.debugDroppedStateWrites, greaterThan(0),
        reason: 'the writes must be dropped, and countable, rather than '
            'silently pretending they happened');
  });

}
