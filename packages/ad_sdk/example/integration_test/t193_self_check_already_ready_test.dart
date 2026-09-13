// T193 on-device integration test — runIntegrationSelfCheck() must report
// PASS immediately for a slot that is already ready (a real, still-fresh
// preloaded ad), not time out waiting for a fresh AdLoadEvent that a real
// adapter's "fresh ad already cached" short-circuit never emits.
//
// The demo app's ad unit ids are placeholders that never actually fill on
// a real network round trip (see debug_overlay_doctor_test.dart's own
// comment on this), so reaching a genuinely `ready` slot here is done by
// marking the real, live adapter's real slot ready directly — this still
// exercises the REAL runIntegrationSelfCheck() code path against the REAL
// AdManager singleton on a real device process; only the precondition
// (an already-ready slot) is seeded directly instead of waiting on an
// unreliable real network fill.
//
// Run with:
//   flutter test integration_test/t193_self_check_already_ready_test.dart -d <device-or-sim-id>

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
      'an already-ready interstitial slot makes runIntegrationSelfCheck '
      'report PASS quickly, on a real device, real AdManager singleton',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // runIntegrationSelfCheck() checks interstitial/rewarded/appOpen in
    // sequence and returns one combined result. AppLovinAdapter's
    // loadInterstitial/loadRewarded/loadAppOpen each check `slotX.isReady`
    // directly and return immediately when true (unlike AdMobAdapter,
    // which instead checks its own cached native-ad-object reference) —
    // so marking all three real slots ready here makes every item
    // resolve instantly without ANY real network attempt, avoiding the
    // demo app's placeholder (never-filling) ad units paying their own
    // real ~30s adapter-level watchdog each.
    final adapter = AdManager().adapter!;
    for (final slot in [
      adapter.interstitialSlot,
      adapter.rewardedSlot,
      adapter.appOpenSlot,
    ]) {
      slot.beginLoad();
      slot.markReady();
      expect(slot.isReady, isTrue);
    }

    final stopwatch = Stopwatch()..start();
    final result = await AdManager().runIntegrationSelfCheck(
        loadTimeout: const Duration(seconds: 15));
    stopwatch.stop();

    final interstitial =
        result.items.firstWhere((i) => i.name == 'Interstitial load');
    expect(interstitial.status, SelfCheckStatus.pass,
        reason: 'a genuinely ready slot must report pass, not a false '
            'timeout fail');
    expect(interstitial.detail, contains('already ready'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'all three slots were pre-marked ready, so the whole '
            'self-check must resolve immediately — a value close to the '
            '15s timeout would mean the readiness-first fix regressed');
  });
}
