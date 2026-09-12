// On-device integration test for T163 — SelfHealingObserver must not go
// permanently silent for a (type, placement, recommendedProvider) key once
// it has fired, across multiple failure/recovery rounds.
//
// Why on-device: this is pure internal timing/dedupe logic, no UI to read
// it back from — same reasoning as r160_last_shown_placement_reset_test.dart
// for another pure-logic per-session mechanism. Full branch coverage
// (near-duplicate suppression, clock-rollback safety) lives in
// test/self_healing_observer_test.dart; this proves the exact same code
// path runs correctly in the real compiled app process, simulating several
// rounds of a network's fill/revenue quality changing over time via a fake
// clock (not a real multi-day wait).
//
// Run with:
//   flutter test integration_test/r163_self_healing_observer_ttl_test.dart \
//     -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a recommendation keeps firing across multiple failure/recovery '
      'rounds on the real device, instead of going silent after the first',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    addTearDown(() => AdManager().debugSetAdapter(null));

    var fakeNow = DateTime(2026, 1, 1);
    final observer = SelfHealingObserver(
      reobserveAfter: const Duration(days: 7),
      debugClock: () => fakeNow,
    );
    await observer.ready;
    addTearDown(observer.dispose);

    final observations = <AdEvent>[];
    final sub = AdManager()
        .events
        .listen((e) => e is AdSelfHealingObserveEvent
            ? observations.add(e)
            : null);
    addTearDown(sub.cancel);

    void feedRound() {
      for (var i = 0; i < 6; i++) {
        AdManager().debugEmit(const AdLoadEvent(
          providerTag: '[Fake]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: false,
        ));
        AdManager().debugEmit(const AdLoadEvent(
          providerTag: '[AdMob]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ));
        AdManager().debugEmit(const AdRevenueEvent(
          providerTag: '[AdMob]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          valueMicros: 5000000,
          currencyCode: 'USD',
        ));
      }
    }

    // Round 1: real device process, real recommendation mechanism.
    feedRound();
    await tester.pump(const Duration(milliseconds: 50));
    expect(observations.length, 1,
        reason: 'round 1 must fire the recommendation');

    // Round 2, well within reobserveAfter: still suppressed (unchanged
    // near-duplicate behavior).
    fakeNow = fakeNow.add(const Duration(hours: 1));
    feedRound();
    await tester.pump(const Duration(milliseconds: 50));
    expect(observations.length, 1,
        reason: 'round 2, too soon — must stay suppressed');

    // Round 3, after reobserveAfter elapses: must fire again.
    fakeNow = fakeNow.add(const Duration(days: 8));
    feedRound();
    await tester.pump(const Duration(milliseconds: 50));
    expect(observations.length, 2,
        reason: 'T163 — round 3, after reobserveAfter, the SAME '
            'recommendation must fire again on the real device — '
            'pre-fix this would have stayed silent forever after round 1');

    // Round 4, another reobserveAfter cycle later: fires a third time,
    // proving this is a genuinely repeatable mechanism, not a one-time
    // unstick.
    fakeNow = fakeNow.add(const Duration(days: 8));
    feedRound();
    await tester.pump(const Duration(milliseconds: 50));
    expect(observations.length, 3,
        reason: 'round 4 — must keep working across MULTIPLE cycles, not '
            'just once');
  });
}
