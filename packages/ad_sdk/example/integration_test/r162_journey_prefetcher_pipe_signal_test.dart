// On-device integration test for T162 — JourneyPrefetcher must keep working
// for a signal string that itself contains a literal '|' (e.g. a route name
// like '/store|deal' under auto-mode).
//
// Why on-device: this is pure internal timing logic (a Dart Map keyed by a
// string built from the signal + ad type), with no UI to visually confirm —
// same reasoning as round37_daily_cap_test.dart and
// r159_placement_cap_strictest_test.dart for other pure-logic per-session
// state. Full branch coverage (including a signal sharing a "|"-prefix with
// another, and multiple "|" in one signal) lives in
// test/journey_prefetcher_test.dart; this proves the exact same code path
// runs correctly in the real compiled app process.
//
// Run with:
//   flutter test integration_test/r162_journey_prefetcher_pipe_signal_test.dart \
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
      'a signal string containing a literal "|" still matches and records '
      'a time-to-show sample, on the real device', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final prefetcher = JourneyPrefetcher();
    addTearDown(prefetcher.dispose);
    AdManager().enableJourneyPrefetcher(prefetcher);
    addTearDown(AdManager().disableJourneyPrefetcher);

    const signal = '/store|deal';
    prefetcher.notifySignal(signal, AdSlotType.interstitial);
    await tester.pump(const Duration(milliseconds: 50));

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[T162 device test]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final avg = prefetcher.averageTimeToShow(signal, AdSlotType.interstitial);
    expect(avg, isNotNull,
        reason: 'T162 — a signal containing "|" must still match its own '
            'internal key on the real device process, not be silently '
            'dropped forever the way the pre-fix split(\'|\') logic did');
  });
}
