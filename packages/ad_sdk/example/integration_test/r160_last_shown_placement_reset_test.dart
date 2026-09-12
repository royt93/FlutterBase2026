// On-device integration test for T160 — destroy() must clear
// `_lastShownPlacement` (the show-time placement used to attribute a
// revenue event correctly, overriding whatever the adapter reports), same
// as every other per-session field `_resetGuardState()` resets. See
// `gaid_reset_on_destroy_integration_test.dart` for the same
// destroy()-clears-session-state contract proven for a different field.
//
// Purely internal state with no UI to read it back from (unlike the GAID
// case, which has a demo page) — this drives the real AdManager()
// singleton directly, on the real device process, the same way
// r159_placement_cap_strictest_test.dart does for another pure-logic
// per-session field. Full unit coverage lives in ad_manager_core_test.dart.
//
// Run with:
//   flutter test integration_test/r160_last_shown_placement_reset_test.dart \
//     -d <device-or-sim-id> --dart-define=SKIP_SPLASH_AD=true

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

AdRevenueEvent _revenueFor(AdPlacement placement) => AdRevenueEvent(
      providerTag: '[T160 device test]',
      type: AdSlotType.interstitial,
      placement: placement,
      valueMicros: 1000,
      currencyCode: 'USD',
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a real destroy() clears _lastShownPlacement so a later revenue '
      'event is not misattributed to the ended session\'s placement',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final mgr = AdManager();
    final beforeEvents = <AdEvent>[];
    final subBefore = mgr.events.listen(beforeEvents.add);

    mgr.debugSetLastShownPlacement(AdSlotType.interstitial, AdPlacement.shop);
    mgr.debugEmit(_revenueFor(AdPlacement.unspecified));
    await tester.pump();
    final before = beforeEvents.whereType<AdRevenueEvent>().last;
    expect(before.placement, AdPlacement.shop,
        reason: 'sanity: the show-time placement must win, proving the '
            'mechanism this fix touches is actually exercised here');
    await subBefore.cancel();

    // destroy() replaces the events StreamController with a fresh one (see
    // its own source) — any subscription made before this point is now
    // listening to a dead stream, exactly like `mgr.events` itself now
    // pointing elsewhere. A fresh subscription is required to observe
    // anything emitted after this.
    await mgr.destroy();
    await tester.pump();

    final afterEvents = <AdEvent>[];
    final subAfter = mgr.events.listen(afterEvents.add);
    addTearDown(subAfter.cancel);

    mgr.debugEmit(_revenueFor(AdPlacement.unspecified));
    await tester.pump();
    final after = afterEvents.whereType<AdRevenueEvent>().last;
    expect(after.placement, AdPlacement.unspecified,
        reason: 'T160 — a real destroy() must clear _lastShownPlacement; '
            'a stale "shop" attribution surviving it would misattribute '
            'this revenue event on the real device process');
  });
}
