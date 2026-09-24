// T136 (round 2 independent review, BLOCKER #3) on-device integration test
// — WaterfallTuner's samples must survive a real dispose()/new-instance
// boundary against the REAL platform SharedPreferences (not the mocked
// in-memory store the unit tests in test/waterfall_tuner_test.dart use),
// proving cross-session accumulation actually works on a real device, not
// just against a test double.
//
// Run with:
//   flutter test integration_test/t136_waterfall_tuner_persistence_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets(
      'samples recorded by one WaterfallTuner instance are still there for '
      'a brand-new instance, against the REAL platform SharedPreferences',
      (tester) async {
    final sessionA = WaterfallTuner();
    // Await the documented `ready` future instead of guessing a pump
    // duration — hydration does real disk I/O (SharedPreferences), and the
    // subscription to live events isn't attached until it completes either
    // (see WaterfallTuner._init's own doc comment).
    await sessionA.ready;

    // minSampleSize is 6. Load-attempt count is summed across both
    // providers (2 each here, sum 4, stays below it alone) — but revenue
    // samples are gated separately, per-provider, on the OTHER (candidate)
    // provider's own count (see recommendation()'s round-61-audit-fix
    // comment) — 1 revenue emit per provider wouldn't ever reach 6 no
    // matter how well persistence works (2026-09-24: this test's original
    // single-emitRevenue-per-session pattern could never pass; found via
    // a real-device diagnostic dump proving the write side was already
    // correct, which narrowed it down to this, not a timing bug).
    for (var i = 0; i < 2; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000);
    for (var i = 0; i < 2; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    for (var i = 0; i < 3; i++) {
      emitRevenue('[AppLovin]', 50000);
    }
    await tester.pump(const Duration(milliseconds: 300));

    expect(
        sessionA.recommendation(
          type: AdSlotType.interstitial,
          placement: AdPlacement.home,
          currentProvider: '[AdMob]',
        ),
        isNull,
        reason: 'sanity: 3 AppLovin revenue samples alone is below '
            'minSampleSize (6)');

    // dispose() is async and awaits its own pending SharedPreferences write
    // chain (with a 2s timeout) specifically so a teardown right after the
    // last event doesn't lose it — must be awaited here, not fire-and-forget
    // (2026-09-24).
    await sessionA.dispose();

    // A brand-new instance — real app restart would look exactly like
    // this: same real on-device SharedPreferences file, different Dart
    // object.
    final sessionB = WaterfallTuner();
    // await ready (2026-09-24), not a guessed pump duration — this is the
    // actual root cause of this test returning null on a real device: the
    // write side was already confirmed correct (see the raw-pref dump
    // above), so the only remaining gap was sessionB reading before its own
    // hydration (real disk I/O) actually finished.
    await sessionB.ready;

    for (var i = 0; i < 2; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000);
    for (var i = 0; i < 2; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    // 3 (session A, already persisted and reloaded above) + 3 here = 6,
    // meeting recommendation()'s per-provider otherRevenueSamples gate.
    for (var i = 0; i < 3; i++) {
      emitRevenue('[AppLovin]', 50000);
    }
    await tester.pump(const Duration(milliseconds: 300));

    final rec = sessionB.recommendation(
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      currentProvider: '[AdMob]',
    );

    expect(rec, isNotNull,
        reason: 'session A\'s samples must still be readable from the REAL '
            'platform SharedPreferences by a brand-new WaterfallTuner — '
            'this is what proves cross-session accumulation works on a '
            'real device, not just against the mocked store the fast unit '
            'tests use');
    expect(rec!.recommendedProvider, '[AppLovin]');

    sessionB.dispose();
  });
}
