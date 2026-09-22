// Round-23 QC (reviewer B, BLOCKER) — the child-directed flag can change
// WHILE the native AppLovin init is running, and MAX only reads it at SDK
// init.
//
// The trigger is an ordinary splash: the host starts `AdManager.initialize()`
// and presents its age gate at the same time. The native MAX init is awaited
// for up to 20 seconds. The parent finishes the age gate inside that window,
// the host calls `setConsent(AdConsent(isAgeRestrictedUser: true))` — and
// nothing carried that across:
//
//   * the adapter was already told `false` and MAX exposes no runtime setter;
//   * `setConsent()`'s own COPPA re-init branch reads `_config ??
//     _lastKnownConfig`, and on a FIRST init both are still null, so the
//     branch never runs;
//   * `initialize()` then installed the live adapter and started preloading.
//
// Result: MAX serving ads to a user the host has declared child-directed.
//
// The fix reconciles on the way out of init: remember the flag the adapter was
// built with, compare it against `_consent` after the await, and discard the
// adapter if it changed. It fails closed, which is the correct direction here —
// AppLovin's own adapter refuses to initialise for a child-directed audience,
// so a mid-init flip now behaves exactly like a flag that was true all along.
// `_lastKnownConfig` is set first, so the existing MJ7/M2 recovery rebuilds
// the adapter if the host later corrects the flag back to false.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds its `initialize()` open on a completer so the test owns the window
/// the real native SDK spends coming up.
class _SlowInitAdapter implements AdProviderAdapter {
  _SlowInitAdapter({this.refuseWhenRestricted = true});

  /// Mirrors AppLovinAdapter: refuses to come up for a child-directed
  /// audience. Turned off in the control test so the "adapter came up fine"
  /// branch is the only thing under test.
  final bool refuseWhenRestricted;

  final Completer<void> gate = Completer<void>();
  final Completer<void> entered = Completer<void>();

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
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;
  @override
  String get tag => '[fake-slow]';

  int initializeCalls = 0;
  int disposeCalls = 0;
  final List<bool> ageRestrictedPerCall = [];

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    initializeCalls++;
    ageRestrictedPerCall.add(isAgeRestrictedUser);
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    if (refuseWhenRestricted && isAgeRestrictedUser) return false;
    return true;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  void applyConsent(AdConsent consent) {}

  // Round-71 flakiness fix — this stub was only ever built to test the COPPA
  // reconcile logic; nothing here exercised the ad-loading surface, so
  // anything past `initialize()` (preload calls, banner/mrec plumbing, etc.)
  // fell through to the default `noSuchMethod`, which throws. That was
  // "safe" only because those calls never fired in practice — under CPU
  // contention from concurrent test workers, a slower reconcile can let a
  // preload slip through before the abort path cancels it, turning a latent
  // gap into a real crash. Same defensive pattern as `_StubAdapter` in
  // `tcf_personalisation_consent_test.dart`: every Future-returning member
  // becomes a safe no-op instead.
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

const _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  autoRequestUmpConsent: false,
  enableCrashGuard: false,
  appLovin: AppLovinConfig(
    sdkKey: 'key',
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

const _adMobConfig = AdConfig(
  provider: AdProvider.admob,
  autoRequestUmpConsent: false,
  enableCrashGuard: false,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

/// The re-init this drives is fired via `unawaited(...)`, and the chain behind
/// it touches several plugin channels that resolve on the event loop rather
/// than as microtasks. Poll on a real (tiny) delay instead of `Duration.zero`
/// so a slower run does not fall out of the loop early.
Future<void> _pumpUntil(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    // Round-71 flakiness fix — several tests here hold `adapter.initialize()`
    // open with a real `Completer` (`_SlowInitAdapter.gate`) across multiple
    // real `await`s (a `_pumpUntil` poll, an `unawaited` setConsent's own
    // internal work) to exercise mid-init consent flips. That implicitly
    // assumes the whole sequence resolves well inside the real 20s adapter
    // init timeout. Under CPU contention from concurrent test-worker
    // isolates, wall-clock time can stretch enough that the real timeout
    // fires first, resetting `_isInitializing` before the test completes its
    // own gate — a later `initialize()` call in the same test (e.g. the
    // COPPA-triggered recovery re-init) then reaches the real
    // AppLovinAdapter instead of this file's stub. A generous override
    // removes the race; it does not affect `ad_bootstrap_test.dart`'s own
    // `fakeAsync`-driven check of the real 20s default, which runs on
    // simulated time and never touches a real clock at all.
    AdManager.debugAdapterInitTimeoutOverride = const Duration(minutes: 2);
    // `AdManager` is a singleton and `destroy()` deliberately does not reset
    // the consent record (it is a user decision, not session state), so every
    // test here has to start from a known child-directed=false. Safe at this
    // point: `destroy()` in the previous tearDown cleared `_lastKnownConfig`,
    // so this cannot trip the COPPA recovery re-init.
    await AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: false,
    ));
  });

  tearDown(() async {
    // Round-71 flakiness fix — `destroy()` cancels any pending init-retry
    // Timer this test armed (several here deliberately leave one scheduled,
    // e.g. "an age gate that answers ADULT mid-init schedules a retry"), but
    // only once its own await chain reaches that point. Nulling the factory
    // FIRST left a real window: under CPU contention from concurrent test
    // workers, a short-delay retry (`debugInitRetryDelays` in some tests
    // here is 20ms) can fire and call `initialize()` again while
    // `debugAdapterFactory` is already null, reaching the REAL
    // AppLovinAdapter/AppLovinMAX plugin instead of this file's stub —
    // MissingPluginException, sometimes reported against a later test
    // ("this test failed after it had already completed"). `destroy()`
    // first closes that window; the factory is only cleared once nothing
    // can read it anymore.
    await AdManager().destroy();
    AdManager.debugAdapterFactory = null;
    AdManager.debugAdapterInitTimeoutOverride = null;
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'AppLovin: COPPA flipped to true during the FIRST init discards the '
      'adapter instead of installing it', () async {
    final adapter = _SlowInitAdapter();
    AdManager.debugAdapterFactory = (config) => adapter;

    bool? reported;
    final init = AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (ok, _) => reported = ok,
    );

    // The native init is now in flight, told `isAgeRestrictedUser: false`.
    await adapter.entered.future;
    expect(adapter.ageRestrictedPerCall.single, isFalse);

    // The age gate finishes on the splash, mid-init.
    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: true,
    )));
    await _pumpUntil(() => AdManager().consent.isAgeRestrictedUser);

    // ...and only then does the native SDK finish coming up.
    adapter.gate.complete();
    await init;
    await _pumpUntil(() => reported != null);

    expect(reported, isFalse,
        reason: 'the host must not be told the SDK is up under a flag the '
            'provider never received');
    expect(AdManager().isInitialised, isFalse);
    expect(adapter.disposeCalls, greaterThanOrEqualTo(1),
        reason: 'the adapter carrying the stale flag has to be released');
    expect(AdManager().canRequestAds, isFalse,
        reason: 'nothing may request an ad for a child-directed user');
  });

  // Round-25 QC (reviewer B, MINOR) — the abort has to SAY so on the bus.
  //
  // `_reportAbandonedInit` is deliberately silent for a *superseded* attempt:
  // a winner is behind it and a late `false` replayed by the bus would tell a
  // splash that subscribed late that init had failed. The COPPA abort is the
  // other shape — there is no winner and no `destroy()`, so nothing else will
  // ever fire, and the SDK's own `AdReadinessSplashController` (and the
  // copy-paste splash in the README) drive navigation off this bus alone. The
  // user sat on a frozen splash until the 8 s hard cap.

  test('the COPPA abort fires BoolEvent(false), so a bus-driven splash moves',
      () async {
    final events = <bool>[];
    SimpleEventBus().clearAll();
    SimpleEventBus().listen((e) => events.add(e.value));
    addTearDown(SimpleEventBus().clearAll);

    final adapter = _SlowInitAdapter();
    AdManager.debugAdapterFactory = (config) => adapter;

    final init = AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (_, __) {},
    );
    await adapter.entered.future;

    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: true,
    )));
    await _pumpUntil(() => AdManager().consent.isAgeRestrictedUser);

    adapter.gate.complete();
    await init;
    await _pumpUntil(() => events.isNotEmpty);

    expect(events, [false],
        reason: 'THE finding — a splash that navigates on this event has '
            'nothing else coming, so silence here is 8 seconds of frozen '
            'splash for every user whose age gate lands mid-init');
  });

  test('the COPPA abort also releases a caller parked behind the in-flight '
      'init', () async {
    // Round-26 QC (reviewer B, MAJOR) — the same sentence that justified
    // firing the event ("nothing else will ever fire") is true of the parked
    // callers. Every other abort path has a winner or a `destroy()` behind it
    // that drains the queue; this one has neither, so a host that awaited a
    // second `initialize()` waited forever.
    final adapter = _SlowInitAdapter();
    AdManager.debugAdapterFactory = (config) => adapter;

    final init = AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (_, __) {},
    );
    await adapter.entered.future;

    // A second caller arrives while the first is still in flight and is parked
    // by the duplicate-init guard.
    bool? parkedResult;
    final parked = AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (ok, _) => parkedResult = ok,
    );

    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: true,
    )));
    await _pumpUntil(() => AdManager().consent.isAgeRestrictedUser);

    adapter.gate.complete();
    await init;
    await _pumpUntil(() => parkedResult != null);

    expect(parkedResult, isFalse,
        reason: 'THE finding — an awaited initialize() that never returns '
            'hangs whatever the host put behind it, forever');
    await parked;
  });

  // Round-30 QC (reviewer B, BLOCKER) — the OTHER direction.
  //
  // Every test above drives the flag `false → true`, where "no ads" is the
  // correct outcome and compliance requires it. Run the same trigger backwards
  // — a kids-category app with a parent-unlockable adult tier boots
  // child-directed, the parent finishes the age gate inside the ≤20 s native
  // window, the host sets `isAgeRestrictedUser: false` — and the abort left an
  // ordinary adult user with no banner, no interstitial, no rewarded and no App
  // Open for the whole session, with nothing in the SDK that would ever try
  // again. Strictly worse than doing nothing: keeping the over-restrictive
  // adapter would at least have served child-safe inventory.

  test('an age gate that answers ADULT mid-init schedules a retry', () async {
    expect(AdManager().debugInitRetryScheduled, isFalse,
        reason: 'sanity — no retry is pending before this test starts, or the '
            'assertion at the end would be measuring another test');

    // Comes up even under the restricted flag, so the COPPA reconcile is
    // reached with a LIVE adapter — otherwise the ordinary init-failure path
    // schedules the retry and this test measures that instead.
    final adapter = _SlowInitAdapter(refuseWhenRestricted: false);
    AdManager.debugAdapterFactory = (config) => adapter;

    await AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: true,
    ));

    final init = AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (_, __) {},
    );
    await adapter.entered.future;
    expect(adapter.ageRestrictedPerCall.single, isTrue,
        reason: 'sanity — the adapter was built child-directed');

    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: false,
    )));
    await _pumpUntil(() => !AdManager().consent.isAgeRestrictedUser);

    adapter.gate.complete();
    await init;

    expect(AdManager().debugInitRetryScheduled, isTrue,
        reason: 'THE finding — the abort is correct (the adapter carries the '
            'stale flag) but stopping there leaves an adult user with zero ads '
            'for the session and no route back');
  });

  // ── Round-33 QC (reviewer B, MAJOR) ─────────────────────────────────────
  //
  // `_scheduleInitRetryIfNeeded` stores `onComplete` verbatim and re-invokes it
  // when the retry lands. Passing that SAME closure through here, on top of the
  // immediate report, queued a second call: a host that stops a splash spinner
  // or fires one "sdk_ready" event off `onComplete` did both, once with the
  // immediate `false` and once more with the retry's real outcome.

  test('onComplete fires exactly once, not twice, when a retry is scheduled',
      () async {
    AdManager.debugInitRetryDelays = const [Duration(milliseconds: 20)];
    addTearDown(() => AdManager.debugInitRetryDelays = null);

    var calls = 0;
    // Comes up even under the restricted flag, so init reaches the reconcile
    // with a LIVE adapter — this is the direction that schedules a retry.
    final adapter = _SlowInitAdapter(refuseWhenRestricted: false);
    AdManager.debugAdapterFactory = (config) => adapter;

    await AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: true,
    ));

    final init = AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (_, __) => calls++,
    );
    await adapter.entered.future;

    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: false, // flips true → false, mid-init: the parent
      // finished the age gate. This is the direction that schedules a retry.
    )));
    await _pumpUntil(() => !AdManager().consent.isAgeRestrictedUser);

    adapter.gate.complete();
    await init;

    // This direction schedules a retry rather than reporting immediately —
    // `onComplete` has not been answered yet, by design.
    expect(calls, 0,
        reason: 'sanity — no immediate report on the recovering direction; '
            'the retry is the only answer coming');

    // Let the retry actually land.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, 1,
        reason: 'THE finding — the previous version handed this SAME '
            'onComplete closure into the retry AND called it immediately '
            'above, so it would have reached 2 here');
  });

  test(
      'the aborted init still remembers the config, so correcting the flag '
      'back to false recovers AppLovin', () async {
    final first = _SlowInitAdapter();
    AdManager.debugAdapterFactory = (config) => first;

    final init = AdManager()
        .initialize(config: _appLovinConfig, onComplete: (_, __) {});
    await first.entered.future;
    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: true,
    )));
    await _pumpUntil(() => AdManager().consent.isAgeRestrictedUser);
    first.gate.complete();
    await init;
    await _pumpUntil(() => !AdManager().isInitialised);
    expect(AdManager().isInitialised, isFalse);

    // The parent corrects a mistyped birth date. MJ7/M2's recovery re-init
    // fires off `_lastKnownConfig` — which only exists because the abort above
    // set it before bailing out.
    final second = _SlowInitAdapter();
    second.gate.complete(); // this one comes up immediately
    AdManager.debugAdapterFactory = (config) => second;
    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: false,
    )));
    await _pumpUntil(() => second.initializeCalls > 0);

    expect(second.initializeCalls, greaterThanOrEqualTo(1),
        reason: 'the recovery re-init had a config to rebuild from');
    expect(second.ageRestrictedPerCall.first, isFalse,
        reason: 'and it carries the corrected flag');
  });

  test(
      'CONTROL — an unchanged flag installs the adapter exactly as before',
      () async {
    final adapter = _SlowInitAdapter();
    AdManager.debugAdapterFactory = (config) => adapter;

    bool? reported;
    final init = AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (ok, _) => reported = ok,
    );
    await adapter.entered.future;
    adapter.gate.complete();
    await init;
    await _pumpUntil(() => reported != null);

    expect(reported, isTrue);
    expect(AdManager().isInitialised, isTrue);
    expect(adapter.disposeCalls, 0,
        reason: 'the reconcile must not fire when nothing changed');
  });

  test(
      'CONTROL — AdMob is untouched: the flag is a per-request field there, '
      'not an init-time one', () async {
    final adapter = _SlowInitAdapter(refuseWhenRestricted: false);
    AdManager.debugAdapterFactory = (config) => adapter;

    bool? reported;
    final init = AdManager().initialize(
      config: _adMobConfig,
      onComplete: (ok, _) => reported = ok,
    );
    await adapter.entered.future;
    unawaited(AdManager().setConsent(const AdConsent(
      hasUserConsent: true,
      isAgeRestrictedUser: true,
    )));
    await _pumpUntil(() => AdManager().consent.isAgeRestrictedUser);
    adapter.gate.complete();
    await init;
    await _pumpUntil(() => reported != null);

    expect(reported, isTrue,
        reason: 'AdMob carries child-directed on every ad request, so there is '
            'nothing stale to discard — tearing its adapter down would be a '
            'regression, not a fix');
    expect(AdManager().isInitialised, isTrue);
  });
}
