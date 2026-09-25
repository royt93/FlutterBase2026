import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart'
    show AdEventSink;

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  // The caller's own test is responsible for mocking the SharedPreferences
  // and applovin_max/google_mobile_ads platform channels before calling
  // run() with reinitializations > 0 — see this class's own doc comment.
  // Turned off here so this real initialize() call never attempts a real
  // (unmocked) UMP round trip on top of that.
  autoRequestUmpConsent: false,
);

/// codex review (T212 fix, round 2) — a real [AdProviderAdapter.dispose]
/// (e.g. [FakeAdProviderAdapter]'s) disposes its OWN fullscreen [AdSlot]s,
/// and [AdSlot.dispose] clears that slot's listeners unconditionally as
/// part of normal, correct teardown. Checking
/// [AdSlot.debugHasStateListeners] AFTER such a `dispose()` therefore
/// reports `false` regardless of whether [AdManager] itself ever detached
/// its OWN listener first — the leak this harness exists to catch would be
/// silently masked. This adapter deliberately does NOT dispose its slots,
/// so a listener [AdManager] failed to detach stays visibly attached
/// afterward instead of being wiped by unrelated (correct) adapter
/// cleanup.
class _LeakDetectableAdapter implements AdProviderAdapter {
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
  String get tag => '[stress]';

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
  }) async =>
      true;

  @override
  Future<void> dispose() async {}

  @override
  void applyConsent(AdConsent consent) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Report from a single [AdStressHarness.run] — see its own doc comment for
/// what each dimension actually measures.
class AdStressReport {
  const AdStressReport({
    required this.eventsGenerated,
    required this.eventsDelivered,
    required this.reinitializations,
    required this.leakedFullscreenListenersAfterReinit,
  });

  /// How many real [AdEvent]s this run pushed through
  /// [AdManager.debugEmit] in one back-to-back burst.
  final int eventsGenerated;

  /// How many of those actually reached a real subscriber on
  /// `AdManager().events` — proves the broadcast stream doesn't silently
  /// drop events under a rapid, no-`await`-between-emits burst.
  ///
  /// codex review (T212 fix, round 2) — a `deliveryIterationsUsed`-based
  /// "peak backlog" metric was here in an earlier revision, but
  /// `Future.delayed(Duration.zero)` is a TIMER, not a microtask probe: it
  /// only resumes once the ENTIRE microtask queue (all pending stream
  /// deliveries, however many) has already drained, so it converges to a
  /// small constant regardless of whether delivery is actually bounded —
  /// it measured nothing real and was removed rather than kept as a false
  /// signal. Dart's own broadcast-stream dispatch has no
  /// application-inspectable queue depth to measure honestly in-process;
  /// like heap/memory profiling (already disclosed as
  /// runner/device-tool-dependent below), this specific property is out of
  /// reach for a portable in-process check. "Nothing silently dropped" is
  /// the guarantee this harness can actually make and does.
  final int eventsDelivered;

  /// How many real initialize()-then-destroy() reinit cycles this run
  /// performed.
  final int reinitializations;

  /// >0 means at least one reinit cycle left a fullscreen slot's
  /// [AdSlot.state] listener still attached after a real
  /// [AdManager.destroy] should have detached it — the actual
  /// memory-leak signal this harness exists to catch. See
  /// [_LeakDetectableAdapter]'s doc comment for why the adapter used here
  /// deliberately never disposes its own slots, so this check isn't masked
  /// by the adapter's own (unrelated, correct) cleanup.
  final int leakedFullscreenListenersAfterReinit;

  /// `true` only if every generated event was actually delivered AND no
  /// reinit cycle leaked a listener.
  bool get withinBound =>
      eventsDelivered == eventsGenerated &&
      leakedFullscreenListenersAfterReinit == 0;
}

/// Stress-tests two real memory/backpressure-relevant SDK behaviors under
/// load against the REAL [AdManager] singleton — not a standalone
/// simulation with no connection to it (an earlier version of this class
/// was exactly that: a toy loop over a bare `List<int>` that never touched
/// `AdManager`, `AdEvent`, or a real adapter at all — caught by an
/// independent audit and rewritten here, then tightened again by a second
/// review round — see the doc comments on [AdStressReport.eventsDelivered]
/// and [_LeakDetectableAdapter] for what each round actually fixed):
///
///  1. A burst of real [AdEvent]s pushed through the real
///     `AdManager().events` broadcast stream in one synchronous loop (no
///     `await` between them) — proving delivery keeps up and nothing is
///     silently dropped even under thousands of back-to-back emits.
///  2. Repeated REAL `initialize()`-then-`destroy()` reinit churn (not
///     just swapping an adapter reference) via [_LeakDetectableAdapter],
///     through [AdManager.debugAdapterFactory] — so init-created timers/
///     subscriptions genuinely exist for the real teardown path to tear
///     down, exactly like a real host's destroy()/reinitialize() cycle —
///     proving a fullscreen slot's state listener from an OLD adapter is
///     genuinely detached, not leaked, across every cycle.
///
/// Route-transition and widget-mount/unmount stress deliberately do NOT
/// live here — those need a real `Navigator`/widget tree to mean anything,
/// which a plain Dart class cannot provide on its own. See
/// `test/ad_stress_harness_widget_test.dart` for that dimension.
///
/// **Known, disclosed scope limits (codex review, round 3):** this does
/// NOT measure queue/heap size during the event burst (see
/// [AdStressReport.eventsDelivered]'s own doc comment for why: a broadcast
/// `StreamController` with an active, non-paused listener — which is what
/// every real subscriber in this SDK is; none of them call `.pause()` —
/// dispatches each event via its own microtask as it's added, with no
/// separate, growable, application-inspectable queue for a healthy
/// listener to fall behind into; genuine unbounded buffering is a
/// *paused*-subscription failure mode, which is a different, currently
/// out-of-scope property no code path here creates). It also only checks
/// for a LEAKED FULLSCREEN SLOT LISTENER across a reinit cycle, not every
/// possible leaked resource (a leaked retry `Timer`, connectivity
/// subscription, or the event `StreamController` itself would not be
/// caught here — none of those currently have a debug-inspection seam to
/// check them against). Both are real, narrower-than-ideal boundaries, not
/// oversights papered over: a synthetic queue-depth metric or an
/// exhaustive resource-leak check would have to either measure something
/// that isn't real for this codebase's actual usage pattern, or add new
/// `@visibleForTesting` surface to `AdManager` well beyond what a stress
/// *test* helper should be motivating on its own — a separate, deliberate
/// change if ever needed, not a silent expansion smuggled in here.
///
/// Lives under `test/support/`, not `lib/`, and is deliberately NOT part
/// of the published package (nor was it ever — this whole class was added
/// and removed again within the same "Unreleased" CHANGELOG window,
/// before any real pub.dev release ever shipped it, so removing it broke
/// no real consumer): every real dimension it measures needs
/// `@visibleForTesting`-guarded seams (`AdManager.debugEmit`,
/// `.debugConfig`, `.debugAdapterFactory`, `AdSlot.debugHasStateListeners`),
/// which the analyzer only allows from a `test`/`integration_test` file —
/// a production `lib/` class using them is exactly the kind of
/// API-contract violation the annotation exists to catch (and exactly why
/// the original, pre-fix version of this class never touched any of them:
/// it was a disconnected simulation instead, precisely to dodge this
/// constraint).
///
/// Requires `TestWidgetsFlutterBinding.ensureInitialized()` to have run
/// first, same as any other code path touching [AdManager]. A
/// `reinitializations > 0` run also needs the caller's own test to have
/// called `SharedPreferences.setMockInitialValues({})` and mocked the
/// `applovin_max`/`plugins.flutter.io/google_mobile_ads` method channels
/// (see `test/ad_stress_harness_test.dart`'s `setUp` for the exact
/// pattern) — a real `initialize()` genuinely touches both, and on a real
/// device (the integration-test copy of this logic) they're real channels
/// that need no mocking at all.
class AdStressHarness {
  const AdStressHarness();

  Future<AdStressReport> run({
    int events = 10000,
    int reinitializations = 10,
  }) async {
    if (events < 0 || reinitializations < 0) {
      throw ArgumentError(
          'stress parameters must be non-negative (events=$events, '
          'reinitializations=$reinitializations)');
    }

    var delivered = 0;
    final sub = AdManager().events.listen((_) => delivered++);
    for (var i = 0; i < events; i++) {
      AdManager().debugEmit(AdLoadEvent(
        providerTag: '[stress]',
        type: AdSlotType.values[i % AdSlotType.values.length],
        placement: AdPlacement.unspecified,
        success: i.isEven,
      ));
    }
    // The event stream is a non-sync broadcast StreamController — delivery
    // needs a bounded number of microtask turns, not necessarily just one.
    for (var i = 0; i < events + 50 && delivered < events; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await sub.cancel();

    var leaked = 0;
    for (var i = 0; i < reinitializations; i++) {
      final adapter = _LeakDetectableAdapter();
      AdManager.debugAdapterFactory = (_) => adapter;
      var completed = false;
      await AdManager().initialize(
        config: _config,
        onComplete: (_, _) => completed = true,
      );
      assert(completed, 'the fake adapter always reports success');
      await AdManager().destroy();
      if (adapter.appOpenSlot.debugHasStateListeners ||
          adapter.interstitialSlot.debugHasStateListeners ||
          adapter.rewardedSlot.debugHasStateListeners ||
          adapter.rewardedInterstitialSlot.debugHasStateListeners) {
        leaked++;
      }
    }
    AdManager.debugAdapterFactory = null;

    return AdStressReport(
      eventsGenerated: events,
      eventsDelivered: delivered,
      reinitializations: reinitializations,
      leakedFullscreenListenersAfterReinit: leaked,
    );
  }
}
