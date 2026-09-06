// T122 — WaterfallTuner unit tests, driven via AdManager().debugEmit (no
// real network/adapter needed — this class only ever reads the event
// stream, it never issues a request of its own).

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WaterfallTuner tuner;

  setUp(() async {
    // T136 — the default WaterfallTuner() now persists across sessions
    // (see the constructor's `persist` doc comment), which touches
    // AdPreferences/SharedPreferences internally.
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    tuner = WaterfallTuner();
    // T136 (round 3 review) — the event listener only attaches once
    // hydration finishes (fixes a real race where a live event could
    // arrive before hydrate and get clobbered by it) — every test here
    // emits events right after construction, so it must wait for `ready`
    // first or those events would have no subscriber yet to reach.
    await tuner.ready;
  });

  tearDown(() {
    tuner.dispose();
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
      networkName: null,
      precision: null,
      mediationWaterfall: null,
    ));
  }

  test('no recommendation with fewer than minSampleSize attempts', () async {
    emitLoad('[AdMob]', success: true);
    emitLoad('[AppLovin]', success: true);
    await Future<void>.delayed(Duration.zero);

    expect(
      tuner.recommendation(
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        currentProvider: '[AdMob]',
      ),
      isNull,
    );
  });

  test(
      'recommends switching when the OTHER provider clearly out-fills and '
      'out-earns the current one', () async {
    // AdMob (current): fills half the time, low eCPM.
    for (var i = 0; i < 6; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000); // $0.001

    // AppLovin: fills every time, much higher eCPM.
    for (var i = 0; i < 6; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000); // $0.05
    await Future<void>.delayed(Duration.zero);

    final rec = tuner.recommendation(
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      currentProvider: '[AdMob]',
    );

    expect(rec, isNotNull);
    expect(rec!.recommendedProvider, '[AppLovin]');
    expect(rec.currentProvider, '[AdMob]');
    expect(rec.recommendedScore, greaterThan(rec.currentScore));
  });

  test('no recommendation when the current provider is already better',
      () async {
    for (var i = 0; i < 6; i++) {
      emitLoad('[AdMob]', success: true);
    }
    emitRevenue('[AdMob]', 50000);

    for (var i = 0; i < 6; i++) {
      emitLoad('[AppLovin]', success: i.isEven);
    }
    emitRevenue('[AppLovin]', 1000);
    await Future<void>.delayed(Duration.zero);

    expect(
      tuner.recommendation(
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        currentProvider: '[AdMob]',
      ),
      isNull,
    );
  });

  test('dispose() stops listening — events after dispose do not move the '
      'score', () async {
    tuner.dispose();
    for (var i = 0; i < 10; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000);
    await Future<void>.delayed(Duration.zero);

    // No crash, and (implicitly) nothing was recorded — re-querying a
    // disposed tuner is safe and just keeps returning null.
    expect(
      tuner.recommendation(
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        currentProvider: '[AdMob]',
      ),
      isNull,
    );
  });

  // Round 2 independent review, BLOCKER — WaterfallTuner's samples used to
  // live only in memory, so they were lost the moment an instance was
  // disposed (every real app process restart included). This is the test
  // that proves T136's actual point: samples recorded by one "session"
  // (one WaterfallTuner instance) are still there for the NEXT one.
  test(
      'samples recorded by one WaterfallTuner instance are still visible '
      'to a brand-new instance backed by the same persisted store — '
      'cross-session accumulation', () async {
    // WaterfallTuner.minSampleSize is 6, summed ACROSS both providers — 2
    // attempts each (sum 4) stays below it on its own; only combined with
    // session B's own 2+2 (sum 8 total) does it cross the threshold.
    for (var i = 0; i < 2; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000);
    for (var i = 0; i < 2; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000);
    await pumpEventQueue(times: 20);

    expect(
        tuner.recommendation(
          type: AdSlotType.interstitial,
          placement: AdPlacement.home,
          currentProvider: '[AdMob]',
        ),
        isNull,
        reason: 'sanity: 2+2=4 attempts alone is below minSampleSize (6)');

    tuner.dispose();

    // Session B: a BRAND NEW instance (as a fresh app launch would create)
    // reading the SAME persisted SharedPreferences store — 2 MORE attempts
    // each brings the combined total to 4+4=8, enough to cross
    // minSampleSize ONLY if session A's samples actually persisted.
    final sessionB = WaterfallTuner();
    await sessionB.ready; // hydrate AND subscribe must both finish first
    for (var i = 0; i < 2; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000);
    for (var i = 0; i < 2; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000);
    await pumpEventQueue(times: 20);

    final rec = sessionB.recommendation(
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      currentProvider: '[AdMob]',
    );

    expect(rec, isNotNull,
        reason: 'session A\'s samples must still be there for session B '
            'to combine with its own — proving samples actually persist '
            'across a dispose()/new-instance boundary, not just within one '
            'process');
    expect(rec!.recommendedProvider, '[AppLovin]');

    sessionB.dispose();
  });

  // Round 2 independent review, MAJOR #3 — hydrate used to accept a
  // persisted list of ANY length verbatim, so a session configured with a
  // SMALLER rollingWindowSize than whatever wrote the persisted blob (or
  // a corrupted/oversized value written some other way) would silently
  // keep scoring on more history than it was configured to.
  test('hydrating a persisted history longer than this instance\'s '
      'rollingWindowSize trims it down, not scores on the full history',
      () async {
    // Write a persisted blob with 20 attempts directly (bypassing a real
    // WaterfallTuner instance, since one always trims its OWN in-memory
    // maps as it goes — this simulates a value from a differently
    // configured session, or a corrupted/oversized write).
    final prefs = await AdPreferences.getInstance();
    await prefs.setWaterfallTunerStateRaw(jsonEncode({
      'loadResults': {
        '[AdMob]\x00interstitial\x00home': List.filled(20, true),
      },
      'revenueMicros': <String, dynamic>{},
    }));

    final small = WaterfallTuner(rollingWindowSize: 3);
    await small.ready;

    // 3 more failures for AdMob — if hydrate correctly trimmed to 3 (this
    // instance's configured window) before these land, the true rate
    // should already reflect mostly failures; if it wrongly kept all 20
    // successes, 3 failures barely move a 20+3-sample average.
    for (var i = 0; i < 3; i++) {
      emitLoad('[AdMob]', success: false);
    }
    emitRevenue('[AdMob]', 1000);
    for (var i = 0; i < 3; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000);
    await pumpEventQueue(times: 20);

    final rec = small.recommendation(
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      currentProvider: '[AdMob]',
    );

    expect(rec, isNotNull,
        reason: 'AdMob\'s fill rate should now be dominated by the 3 '
            'recent failures, not diluted by 20 stale successes hydrate '
            'should have trimmed away');
    expect(rec!.recommendedProvider, '[AppLovin]');

    small.dispose();
  });

  // Round 2 independent review, MAJOR #2 — persisted writes used to be
  // pure fire-and-forget with no way for dispose() to know one was still
  // in flight, so a dispose() immediately after the last event of a
  // session could return before that event's write actually landed.
  test('dispose() awaits the in-flight persisted write — the last event '
      'before disposing is not lost even though its persisted write has '
      'not settled yet', () async {
    for (var i = 0; i < 3; i++) {
      emitLoad('[AdMob]', success: true);
      emitLoad('[AppLovin]', success: false);
    }
    // AdManager().events is a plain (non-sync) broadcast StreamController,
    // so delivery to _onEvent needs at least one microtask turn — this one
    // `Future.delayed(Duration.zero)` is only for THAT stream-delivery
    // step, not for the persisted write itself. No further delay/
    // pumpEventQueue after this: dispose() itself must be the thing that
    // waits for the write this last pair of events queued.
    await Future<void>.delayed(Duration.zero);
    await tuner.dispose();

    final prefs = await AdPreferences.getInstance();
    final raw = prefs.getWaterfallTunerStateRaw();
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!) as Map<String, dynamic>;
    final admobResults =
        (decoded['loadResults'] as Map)['[AdMob]\x00interstitial\x00home'];

    expect(admobResults, hasLength(3),
        reason: 'all 3 AdMob load events must have reached disk by the '
            'time dispose() returns, not just whichever had already '
            'settled before dispose() happened to be called');
  });
}
