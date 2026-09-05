// On-device integration test for round-37 audit — the daily/per-placement ad
// count high-water-mark fix.
//
// Why on-device: `AdPreferences` persists through the real native
// `shared_preferences` plugin, not a mocked map — `vip_clock_forward_test.dart`
// established the same pattern for the VIP clock-rollback guard this fix
// mirrors. A guard that only works against an in-memory map would be
// worthless; full bit/branch coverage (including the "clock legitimately
// advances" CONTROL) lives in `test/ad_preferences_test.dart`.
//
// This does NOT change the device's real system clock — that would corrupt
// every other timestamp on it. Instead it calls the same `{DateTime? now}`
// testing seam the unit test uses, directly against the real on-device
// store, which is exactly what a real clock change would look like from
// this code's point of view.
//
// Run with:
//   flutter test integration_test/round37_daily_cap_test.dart -d <device-or-sim-id>
//
// `AdPreferences` is a real on-device singleton whose SharedPreferences file
// persists across tests, across runs, AND across days (the same pitfall
// `us_privacy_propagation_test.dart` documents for `ConsentSettings`) — a
// first version of this file asserted an absolute count starting at 0/1 for
// a hardcoded day and failed on the real S24 Ultra smoke test the SECOND
// time it ran that same day (expected 1, got 6: the first run's leftover
// count was still there). Every assertion below reads its own baseline
// first and checks the CHANGE, never an assumed-fresh absolute value — the
// same philosophy that file's own tests use for exactly this reason. Days
// are anchored to the real device clock at run time rather than a fixed
// calendar date, so the suite keeps working call after call, day after day.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Independent review (round 37 verification, MAJOR) — the CONTROL test
// below writes `farFuture = now + 365 days` through the real on-device
// `AdPreferences`, which persists it as the daily-date high-water-mark.
// Without cleanup this clamps the real daily-cap clock ~366 days into the
// future on whatever device runs this file, blocking every ad the safety
// cap gates for the better part of a year. These key names mirror the
// private constants in `lib/src/utils/ad_preferences.dart` exactly (same
// reach-into-real-storage pattern `round37_gpp_privacy_test.dart` uses for
// GPP keys) so the snapshot/restore below hits the real values, not a
// guess.
const _keyDailyDateHighWaterMark = 'ad_sdk_daily_date_high_water_mark';
const _keyDailyDate = 'ad_sdk_daily_date';
const _keyDailyAdCount = 'ad_sdk_daily_count';

class _Snapshot {
  _Snapshot(this.highWaterMark, this.dailyDate, this.dailyCount);
  final String? highWaterMark;
  final String? dailyDate;
  final int? dailyCount;
}

Future<_Snapshot> _snapshot(SharedPreferences store) async => _Snapshot(
      store.getString(_keyDailyDateHighWaterMark),
      store.getString(_keyDailyDate),
      store.getInt(_keyDailyAdCount),
    );

Future<void> _restore(SharedPreferences store, _Snapshot s) async {
  Future<void> setOrRemove(String key, Object? value) => value == null
      ? store.remove(key)
      : (value is int ? store.setInt(key, value) : store.setString(key, value as String));
  await setOrRemove(_keyDailyDateHighWaterMark, s.highWaterMark);
  await setOrRemove(_keyDailyDate, s.dailyDate);
  await setOrRemove(_keyDailyAdCount, s.dailyCount);
  AdPreferences.resetForTest();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'daily ad count survives the clock reporting an earlier day than one '
      'already observed, on the real on-device store', (tester) async {
    final store = await SharedPreferences.getInstance();
    final snapshot = await _snapshot(store);
    addTearDown(() => _restore(store, snapshot));

    final prefs = await AdPreferences.getInstance();
    final today = DateTime.now().toUtc();
    final yesterday = today.subtract(const Duration(days: 1));

    final baseline = prefs.getDailyAdCount(now: today);
    for (var i = 0; i < 5; i++) {
      await prefs.incrementDailyAdCount(now: today);
    }
    expect(prefs.getDailyAdCount(now: today), baseline + 5,
        reason: 'sanity: the real on-device store actually persisted 5 '
            'more increments than whatever was already there today');

    expect(prefs.getDailyAdCount(now: yesterday), baseline + 5,
        reason: 'a day that looks earlier than one already observed on '
            'this real device must not reset the counter — that would '
            'defeat the safety cap protecting the AdMob account');
  });

  testWidgets(
      'CONTROL — a real forward day change still rolls the counter over on '
      'the real on-device store', (tester) async {
    final store = await SharedPreferences.getInstance();
    final snapshot = await _snapshot(store);
    addTearDown(() => _restore(store, snapshot));

    final prefs = await AdPreferences.getInstance();
    // Anchored a year out so it can never collide with "today" in the test
    // above, this run or a future one.
    final farFuture = DateTime.now().toUtc().add(const Duration(days: 365));
    final dayAfter = farFuture.add(const Duration(days: 1));

    final baseline = prefs.getDailyAdCount(now: farFuture);
    await prefs.incrementDailyAdCount(now: farFuture);
    expect(prefs.getDailyAdCount(now: farFuture), baseline + 1,
        reason: 'sanity: the increment landed on top of whatever baseline '
            'was already there for this day');

    expect(prefs.getDailyAdCount(now: dayAfter), 0,
        reason: 'a real, forward day change must still roll the counter '
            'over to 0 on this real device, regardless of what the '
            'previous day\'s count was');
  });
}
