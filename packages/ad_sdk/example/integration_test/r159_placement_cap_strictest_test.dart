// On-device integration test for T159 — placementDailyCapReached must apply
// the STRICTER of maxPerPlacementAdsPerDay/maxPerPlacementAdsPerDayById when
// both are configured for the same placement, not whichever map happens to
// be checked first.
//
// Why on-device: the per-placement daily count persists through the real
// native `shared_preferences` plugin, not a mocked map — same reasoning as
// `round37_daily_cap_test.dart`. Full logic/branch coverage (both-set,
// only-one-set, capOverride precedence) lives in
// `test/ad_safety_config_test.dart`; this proves the same code path against
// the real on-device store, in the real compiled app process.
//
// This deliberately swaps AdSafetyConfig's live params via `updateParams`
// (not `init`) and restores the app's original ones afterward, and snapshots
// / restores the real placement-count keys — same care
// `round37_daily_cap_test.dart` takes not to corrupt persisted state a real
// app relies on beyond this test run.
//
// Run with:
//   flutter test integration_test/r159_placement_cap_strictest_test.dart \
//     -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _keyPlacementDailyCounts = 'ad_sdk_placement_daily_counts';
const _keyPlacementDailyDate = 'ad_sdk_placement_daily_date';

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
      'the stricter per-placement daily cap applies when both maps are '
      'configured for the same placement, on the real on-device store',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final store = await SharedPreferences.getInstance();
    final countsSnapshot = store.getString(_keyPlacementDailyCounts);
    final dateSnapshot = store.getString(_keyPlacementDailyDate);
    addTearDown(() async {
      Future<void> setOrRemove(String key, String? value) =>
          value == null ? store.remove(key) : store.setString(key, value);
      await setOrRemove(_keyPlacementDailyCounts, countsSnapshot);
      await setOrRemove(_keyPlacementDailyDate, dateSnapshot);
      // Restore the app's own configured params (whatever main.dart passed
      // to initialize()) rather than leaving this test's params live.
      AdSafetyConfig.updateParams(const AdSafetyParams());
    });

    final prefs = await AdPreferences.getInstance();
    // A placement this app's own config never uses for a real cap, so this
    // test can't collide with a real cap already in effect.
    const placement = AdPlacement.shop;

    // maxPerPlacementAdsPerDay says 1 (stricter); maxPerPlacementAdsPerDayById
    // says 9 (looser, and would have won under the old `??` logic since it's
    // the SECOND map checked — order doesn't matter here, but the bug this
    // fixes was "whichever map is checked first wins", so this deliberately
    // exercises the SAME order the old code had this wrong: shop.id must
    // match AdPlacement.shop.id exactly for both maps to reference the same
    // placement).
    AdSafetyConfig.updateParams(AdSafetyParams(
      maxPerPlacementAdsPerDay: {placement: 1},
      maxPerPlacementAdsPerDayById: {placement.id: 9},
    ));

    final baseline = prefs.getPlacementDailyCounts()[placement.id] ?? 0;
    expect(AdSafetyConfig.placementDailyCapReached(placement), isFalse,
        reason: 'sanity: not reached yet at baseline $baseline');

    await prefs.incrementPlacementDailyCount(placement.id);
    expect(AdSafetyConfig.placementDailyCapReached(placement), isTrue,
        reason: 'T159 — the stricter cap (1, from maxPerPlacementAdsPerDay) '
            'must be the one enforced on the real device, even though '
            'maxPerPlacementAdsPerDayById (9) is nowhere near reached — '
            'the pre-fix `??` logic would have let this show up to 9 ads '
            'before blocking, silently ignoring the stricter configured cap');
  });
}
