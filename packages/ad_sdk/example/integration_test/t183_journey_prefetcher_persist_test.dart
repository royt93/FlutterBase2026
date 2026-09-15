// T183 on-device integration test — a rolling time-to-show sample recorded
// by one JourneyPrefetcher instance must survive and be visible to a
// brand-new instance backed by the SAME real on-device SharedPreferences
// store — the actual point of this task (no more re-learning timing from
// zero on every cold start), proven against real disk I/O, not a mock.
//
// Run with:
//   flutter test integration_test/t183_journey_prefetcher_persist_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a sample recorded by one instance survives to a brand-new instance '
      'reading the same real on-device SharedPreferences store',
      (tester) async {
    // Session A: record one real sample.
    final sessionA = JourneyPrefetcher();
    await sessionA.ready;

    sessionA.notifySignal('levelStarted', AdSlotType.interstitial);
    await tester.pump(const Duration(milliseconds: 20));
    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await tester.pump();

    expect(
        sessionA.averageTimeToShow('levelStarted', AdSlotType.interstitial),
        isNotNull,
        reason: 'sanity: session A itself recorded the sample');

    // dispose() awaits the in-flight persisted write — this is what
    // guarantees session B below actually sees it, on real disk I/O.
    await sessionA.dispose();

    // Session B: a brand-new instance, as a real cold start after an OS
    // kill would create, reading the SAME real on-device
    // SharedPreferences store.
    final sessionB = JourneyPrefetcher();
    addTearDown(sessionB.dispose);
    await sessionB.ready;

    expect(
      sessionB.averageTimeToShow('levelStarted', AdSlotType.interstitial),
      isNotNull,
      reason: 'session A\'s sample must have hydrated into session B from '
          'real on-device SharedPreferences — this is the whole point of '
          'T183',
    );
    expect(tester.takeException(), isNull);
  });
}
