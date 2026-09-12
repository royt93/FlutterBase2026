// On-device integration test for T165 — the fill-rate baseline monitor's
// day computation must stay in sync with the anti-fraud daily-cap
// counters' UTC-based day, not drift on a device with a non-UTC local
// timezone.
//
// Why on-device: this exercises the REAL `AdPreferences`/
// `FillRateBaselineMonitor` singletons backed by the real native
// `shared_preferences` plugin, not a mocked store — same reasoning as
// round37_daily_cap_test.dart for the sibling anti-fraud counters this
// fix is meant to stay synchronized with. Full branch coverage (UTC day
// boundary, clock-rollback-anchored retention) lives in
// test/ad_preferences_test.dart; this proves the exact same code path on
// the real device process.
//
// Actually changing the device's system timezone via adb was deliberately
// avoided (intrusive, and awkward to reliably restore afterward on a
// shared test device) — the fix itself takes an explicit `now` parameter
// specifically so this can be proven without touching real device
// settings, the same approach r160/r162/r164's device tests already use
// for other pure-logic per-session mechanisms with no UI to read back.
//
// Run with:
//   flutter test integration_test/r165_fillrate_baseline_timezone_sync_test.dart \
//     -d <device-or-sim-id> --dart-define=SKIP_SPLASH_AD=true

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
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
      'a fill-rate sample and the anti-fraud daily counter agree on "today" '
      'for the same moment, right at a UTC day boundary, on the real '
      'device store', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final prefs = await AdPreferences.getInstance();

    // 23:30 UTC — a moment a device in a timezone AHEAD of UTC (e.g.
    // UTC+9) would already consider the FOLLOWING calendar day in local
    // time. Before this fix, the fill-rate baseline's local-time read
    // would key this sample under a different day than the anti-fraud
    // counter's UTC-based one whenever THIS real device's own local
    // timezone put it on the other side of that boundary.
    final moment = DateTime.utc(2026, 9, 11, 23, 30);

    await prefs.recordFillRateBaselineSample(
      slotTypeName: AdSlotType.interstitial.name,
      attempts: 1,
      successes: 1,
      now: moment,
    );
    await prefs.incrementDailyAdCount(now: moment);

    final fillRateDayKeys = prefs.getFillRateBaselineHistory(now: moment).keys;
    final antiFraudDay = prefs.todayUtcClamped(now: moment);

    expect(fillRateDayKeys, contains(antiFraudDay),
        reason: 'T165 — on the real device store, the fill-rate sample '
            'must land under the exact same UTC calendar day the '
            'anti-fraud daily-cap counter uses for the same moment');
  });
}
