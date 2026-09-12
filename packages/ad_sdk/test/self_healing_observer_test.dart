// T127 — SelfHealingObserver unit tests, driven via AdManager().debugEmit
// (no real network/adapter needed). Confirms the OBSERVE-ONLY contract: an
// AdSelfHealingObserveEvent appears on the stream when the trailing data
// recommends a switch, and — critically — nothing about the active
// adapter/slot state ever changes because of it.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SelfHealingObserver observer;
  late FakeAdProviderAdapter adapter;

  setUp(() async {
    // T136 — the default SelfHealingObserver() (and the WaterfallTuner it
    // wraps) now persists across sessions by default, which touches
    // AdPreferences/SharedPreferences internally.
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    observer = SelfHealingObserver();
    // T136 (round 3 review) — the event listener only attaches once
    // hydration finishes; every test here emits events right after
    // construction, so it must wait for `ready` first.
    await observer.ready;
  });

  tearDown(() {
    observer.dispose();
    AdManager().debugSetAdapter(null);
  });

  void emitLoad(String provider, {required bool success}) {
    AdManager().debugEmit(AdLoadEvent(
      providerTag: provider,
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      success: success,
    ));
  }

  void emitRevenue(String provider, int valueMicros) {
    AdManager().debugEmit(AdRevenueEvent(
      providerTag: provider,
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      valueMicros: valueMicros,
      currencyCode: 'USD',
    ));
  }

  test('no adapter set → never observes anything, even with lopsided data',
      () async {
    AdManager().debugSetAdapter(null);
    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    addTearDown(sub.cancel);

    for (var i = 0; i < 10; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<AdSelfHealingObserveEvent>(), isEmpty);
  });

  test(
      'emits AdSelfHealingObserveEvent once the OTHER provider clearly '
      'out-fills and out-earns the current one', () async {
    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    addTearDown(sub.cancel);

    // Current provider ('[Fake]', per the injected adapter's tag) fails a
    // lot and earns little; '[AdMob]' fills reliably and earns well.
    for (var i = 0; i < 6; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await Future<void>.delayed(Duration.zero);

    final observed = events.whereType<AdSelfHealingObserveEvent>().toList();
    expect(observed, hasLength(1),
        reason: 'exactly one observation for this (type, placement) pair');
    expect(observed.single.providerTag, '[Fake]');
    expect(observed.single.wouldSwitchToProvider, '[AdMob]');
    expect(observed.single.recommendedScore,
        greaterThan(observed.single.currentScore));

    // OBSERVE-ONLY contract: nothing about the active adapter changed.
    expect(AdManager().adapter, same(adapter));
    expect(AdManager().adapter?.tag, '[Fake]');
  });

  test('does not re-emit the same (type, placement, recommendation) twice',
      () async {
    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    addTearDown(sub.cancel);

    for (var i = 0; i < 12; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<AdSelfHealingObserveEvent>(), hasLength(1),
        reason: 'a recommendation that keeps holding must not spam the '
            'event stream on every subsequent event');
  });

  // Round 2 independent review — WaterfallTuner's samples now persist
  // across sessions (T136), which on its own would make a brand-new
  // SelfHealingObserver instance re-fire the SAME recommendation on every
  // single launch, since a fresh in-memory `_alreadyObserved` set never
  // remembers a PRIOR session already reported it. This is the test that
  // proves the dedupe itself also survives the dispose()/new-instance
  // boundary, not just the underlying tuner data.
  test(
      'a recommendation already observed in a prior session is NOT '
      're-reported by a brand-new instance backed by the same persisted '
      'store', () async {
    final eventsA = <AdEvent>[];
    final subA = AdManager().events.listen(eventsA.add);

    for (var i = 0; i < 6; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await pumpEventQueue(times: 20);

    expect(eventsA.whereType<AdSelfHealingObserveEvent>(), hasLength(1),
        reason: 'sanity: session A fired its one observation');

    await subA.cancel();
    observer.dispose();

    final sessionB = SelfHealingObserver();
    await sessionB.ready; // hydrate AND subscribe must both finish first
    final eventsB = <AdEvent>[];
    final subB = AdManager().events.listen(eventsB.add);
    addTearDown(subB.cancel);
    addTearDown(sessionB.dispose);

    // Same (still-holding) recommendation, MORE events of the exact same
    // shape — a fresh in-memory-only dedupe would treat this as brand new.
    for (var i = 0; i < 6; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await pumpEventQueue(times: 20);

    expect(eventsB.whereType<AdSelfHealingObserveEvent>(), isEmpty,
        reason: 'session A already reported this exact (type, placement, '
            'recommendedProvider) — the persisted dedupe must carry over, '
            'not just the underlying WaterfallTuner sample data');
  });

  // Round 2 independent review, MAJOR #2 — mirrors WaterfallTuner's own
  // dispose-flush test: the persisted dedupe write must not be lost just
  // because dispose() was called right after the observation fired.
  test('dispose() awaits the in-flight dedupe write — the observation '
      'that just fired is not lost even though its persisted write has '
      'not settled yet', () async {
    for (var i = 0; i < 6; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    // Same reasoning as the WaterfallTuner test — one microtask turn for
    // AdManager().events (a plain, non-sync broadcast StreamController) to
    // actually deliver the last event to _onEvent, no further delay:
    // dispose() itself must be what waits for the write it queues.
    await Future<void>.delayed(Duration.zero);
    await observer.dispose();

    final prefs = await AdPreferences.getInstance();
    expect(prefs.getSelfHealingObservedAt(), isNotEmpty,
        reason: 'the observation fired by the loop above must have '
            'reached disk by the time dispose() returns');
  });

  // T163 — the ORIGINAL `Set<String>` dedupe blocked a key FOREVER once it
  // had fired once, with no way for a genuinely later, real need for the
  // exact same recommendation to ever fire again. reobserveAfter bounds
  // that instead: still suppresses a near-duplicate (the existing "does
  // not re-emit twice" test above), but lets the same key fire again once
  // enough time has passed.
  group('reobserveAfter (T163) — the same key can fire again after enough '
      'time, not never', () {
    test(
        'a recommendation observed once stays silent for a SECOND round '
        'within reobserveAfter, then fires again once it elapses',
        () async {
      // The shared `observer` from setUp() would also react to every
      // emitted event below and race this test's own persisted dedupe
      // state — same reason the "prior session" test above disposes it
      // before constructing its own instance.
      await observer.dispose();

      var fakeNow = DateTime(2026, 1, 1);
      final ttlObserver = SelfHealingObserver(
        reobserveAfter: const Duration(days: 7),
        debugClock: () => fakeNow,
      );
      await ttlObserver.ready;
      addTearDown(ttlObserver.dispose);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);
      addTearDown(sub.cancel);

      void feedLopsidedData() {
        for (var i = 0; i < 6; i++) {
          emitLoad('[Fake]', success: false);
          emitLoad('[AdMob]', success: true);
          emitRevenue('[AdMob]', 5000000);
        }
      }

      feedLopsidedData();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AdSelfHealingObserveEvent>(), hasLength(1),
          reason: 'sanity: first round fires the recommendation');

      // A second round of the exact same data, clock barely moved — must
      // still be suppressed (the near-duplicate-in-a-row behavior this
      // mechanism has always had, and must keep).
      fakeNow = fakeNow.add(const Duration(hours: 1));
      feedLopsidedData();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AdSelfHealingObserveEvent>(), hasLength(1),
          reason: 'still just the one — too soon to re-fire');

      // Now advance PAST reobserveAfter and feed the exact same data a
      // third time.
      fakeNow = fakeNow.add(const Duration(days: 8));
      feedLopsidedData();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AdSelfHealingObserveEvent>(), hasLength(2),
          reason: 'T163 — once reobserveAfter has elapsed, the SAME '
              '(type, placement, recommendedProvider) key must be able '
              'to fire again. Pre-fix, a Set-based "ever observed" '
              'dedupe would have kept this silent forever after the '
              'very first round, with no way back — the exact bug this '
              'task fixes.');
    });

    // codex re-review (P2) — a device clock correction backward (NTP
    // resync, a wrong manual clock setting fixed) must not recreate the
    // silent-forever bug this whole mechanism exists to fix.
    test(
        'a device clock rollback since the last observation does NOT keep '
        'the key suppressed — it fires again immediately, not months/years '
        'later', () async {
      await observer.dispose();

      var fakeNow = DateTime(2026, 6, 1);
      final ttlObserver = SelfHealingObserver(
        reobserveAfter: const Duration(days: 7),
        debugClock: () => fakeNow,
      );
      await ttlObserver.ready;
      addTearDown(ttlObserver.dispose);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);
      addTearDown(sub.cancel);

      void feedLopsidedData() {
        for (var i = 0; i < 6; i++) {
          emitLoad('[Fake]', success: false);
          emitLoad('[AdMob]', success: true);
          emitRevenue('[AdMob]', 5000000);
        }
      }

      feedLopsidedData();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AdSelfHealingObserveEvent>(), hasLength(1));

      // Clock corrected BACKWARD past the observation just recorded — a
      // naive `elapsed < reobserveAfter` check would read this as a large
      // NEGATIVE elapsed duration, which compares as "less than" 7 days
      // just like a small positive one would, and stay suppressed for
      // (fakeNow's original distance in the future) + 7 more days.
      fakeNow = fakeNow.subtract(const Duration(days: 30));
      feedLopsidedData();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AdSelfHealingObserveEvent>(), hasLength(2),
          reason: 'T163 (codex re-review) — a clock rollback since the '
              'last observation must be treated as immediately expired, '
              'not as "still fresh"');
    });

    test('defaults to 7 days when not overridden', () async {
      final defaultObserver = SelfHealingObserver();
      addTearDown(defaultObserver.dispose);
      expect(defaultObserver.reobserveAfter, const Duration(days: 7));
    });
  });
}
