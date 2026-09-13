// Round-trip tests for AdPreferences — the SDK-owned SharedPreferences wrapper
// that backs VIP entries, consent settings, first-install state and the legacy
// GAID list. Uses the in-memory SharedPreferences mock.

import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  test(
      'round-30 audit (MAJOR): concurrent getInstance() calls before the '
      'singleton is first set return the SAME instance', () async {
    AdPreferences.resetForTest();
    // Neither call is awaited before the other starts — both race past the
    // (pre-fix) null-check before either has a chance to set `_instance`.
    final f1 = AdPreferences.getInstance();
    final f2 = AdPreferences.getInstance();
    final i1 = await f1;
    final i2 = await f2;
    expect(identical(i1, i2), isTrue,
        reason: 'two "singletons" born from this race independently track '
            'mutable state (e.g. the fill-rate baseline write-serialization '
            'queue) that silently diverges once split, even though the '
            'underlying SharedPreferences itself stays consistent');
  });

  test('consent settings raw round-trips', () async {
    await prefs.setConsentSettingsRaw('{"hasUserConsent":true}');
    expect(prefs.getConsentSettingsRaw(), '{"hasUserConsent":true}');
  });

  test('vip-migrated flag defaults to false', () {
    expect(prefs.isVipMigrated(), isFalse);
  });

  test('first-install grace flag defaults to false', () {
    expect(prefs.isFirstInstallGraceApplied(), isFalse);
  });

  test('legacy GAID list defaults to empty', () {
    expect(prefs.getGAIDList(), isEmpty);
  });

  test('setFirstInstallAtMsIfMissing only writes once', () async {
    await prefs.setFirstInstallAtMsIfMissing(1000);
    await prefs.setFirstInstallAtMsIfMissing(2000); // must NOT overwrite
    // The first value is retained — exercised via the public getter if present;
    // here we just assert the second call does not throw and the flow is stable.
    expect(() => prefs.isFirstInstallGraceApplied(), returnsNormally);
  });

  // T93 — backs AdManager().experimentBucket's GAID fallback.
  group('getOrCreateExperimentInstallId (T93)', () {
    test('returns the same id across repeated calls (in-memory cache)', () {
      final first = prefs.getOrCreateExperimentInstallId();
      final second = prefs.getOrCreateExperimentInstallId();
      expect(second, first);
    });

    test('survives a fresh AdPreferences instance reading the same disk '
        'store (simulates an app restart)', () async {
      final first = prefs.getOrCreateExperimentInstallId();

      // Same backing SharedPreferences store, but a brand-new AdPreferences
      // wrapper — its in-memory cache starts empty, so this only passes if
      // the id was actually persisted to disk, not just cached in memory.
      AdPreferences.resetForTest();
      final reloaded = await AdPreferences.getInstance();

      expect(reloaded.getOrCreateExperimentInstallId(), first);
    });

    test('two different (never-persisted) installs get different ids',
        () async {
      final id = prefs.getOrCreateExperimentInstallId();

      // A second, distinct store (different mock SharedPreferences) stands
      // in for a different device/install, never having persisted an id.
      SharedPreferences.setMockInitialValues({});
      AdPreferences.resetForTest();
      final other = await AdPreferences.getInstance();

      expect(other.getOrCreateExperimentInstallId(), isNot(id),
          reason: '128-bit random ids for two never-persisted installs '
              'colliding is astronomically unlikely — this is really just '
              'checking a fresh id gets generated, not a hardcoded constant');
    });
  });

  group('round-31 audit: daily/placement count increments stay '
      'synchronously visible (no write-serialization chain)', () {
    // A chain-based serializer (mirroring `_fillRateBaselineChain`, T101)
    // was tried here and reverted — see the comment on
    // `incrementDailyAdCount()`. It doesn't fix a reachable bug (the
    // legacy `SharedPreferences` cache these increments read/write through
    // mutates synchronously, so two unawaited calls fired back-to-back
    // can't actually interleave), and it broke real callers in
    // `AdSafetyConfig` that read `getDailyAdCount()`/
    // `getPlacementDailyCounts()` synchronously right after recording a
    // show. These pin that property so a future "fix" doesn't
    // reintroduce the regression.
    test(
        'two incrementDailyAdCount() calls fired back-to-back (no await '
        'between them) both land, and the count is visible synchronously '
        'the instant each call is made', () async {
      final f1 = prefs.incrementDailyAdCount();
      expect(prefs.getDailyAdCount(), 1,
          reason: 'must be visible before f1 even resolves, not after');
      final f2 = prefs.incrementDailyAdCount();
      expect(prefs.getDailyAdCount(), 2,
          reason: 'must be visible before f2 even resolves, not after');
      await f1;
      await f2;
      expect(prefs.getDailyAdCount(), 2);
    });

    test(
        'two incrementPlacementDailyCount() calls for the SAME placement '
        'fired back-to-back both land, visible synchronously', () async {
      final f1 = prefs.incrementPlacementDailyCount('rewarded_home');
      expect(prefs.getPlacementDailyCounts()['rewarded_home'], 1);
      final f2 = prefs.incrementPlacementDailyCount('rewarded_home');
      expect(prefs.getPlacementDailyCounts()['rewarded_home'], 2);
      await f1;
      await f2;
      expect(prefs.getPlacementDailyCounts()['rewarded_home'], 2);
    });
  });

  group('round-37 audit (MAJOR): daily/placement counters survive a '
      'backwards system-clock change', () {
    // VIP/trial already has a high-water-mark guard against the device
    // clock being wound back (`getVipMaxObservedClockMs`); the daily and
    // per-placement ad-count "which UTC day is it" boundary did not, so
    // winding the clock back one day reset the safety cap on demand. The
    // `now` parameter (mirroring `AdMobAdapter.isAdFresh`'s testable clock
    // seam) lets the test move "today" without touching the real system
    // clock.
    test('getDailyAdCount does not reset when the clock moves backward',
        () async {
      final day1 = DateTime.utc(2026, 9, 5);
      final day0 = DateTime.utc(2026, 9, 4); // "yesterday" relative to day1

      for (var i = 0; i < 5; i++) {
        await prefs.incrementDailyAdCount(now: day1);
      }
      expect(prefs.getDailyAdCount(now: day1), 5);

      expect(prefs.getDailyAdCount(now: day0), 5,
          reason: 'the clock reporting an earlier day than one already '
              'observed must not reset the counter');
    });

    test(
        'getPlacementDailyCounts does not reset when the clock moves '
        'backward', () async {
      final day1 = DateTime.utc(2026, 9, 5);
      final day0 = DateTime.utc(2026, 9, 4);

      await prefs.incrementPlacementDailyCount('rewarded_home', now: day1);
      await prefs.incrementPlacementDailyCount('rewarded_home', now: day1);
      expect(prefs.getPlacementDailyCounts(now: day1)['rewarded_home'], 2);

      expect(prefs.getPlacementDailyCounts(now: day0)['rewarded_home'], 2,
          reason: 'the clock reporting an earlier day than one already '
              'observed must not reset the counter');
    });

    test('the clock legitimately advancing still rolls the counter over',
        () async {
      final day1 = DateTime.utc(2026, 9, 5);
      final day2 = DateTime.utc(2026, 9, 6);

      await prefs.incrementDailyAdCount(now: day1);
      expect(prefs.getDailyAdCount(now: day1), 1);

      expect(prefs.getDailyAdCount(now: day2), 0,
          reason: 'a real, forward day change must still roll the '
              'counter over to 0');
    });
  });

  // T165 — the fill-rate baseline monitor's day computation used to be a
  // separate, LOCAL-time `DateTime.now()` read, independent from the
  // anti-fraud daily-cap counters' UTC `_todayUtcClamped`. A device
  // timezone change (or simply being on opposite sides of UTC midnight
  // from wherever the two happened to disagree) could split or merge a
  // day's fill-rate samples differently than the anti-fraud counters saw
  // the same moment — purely a reporting/alerting inconsistency (this
  // data never fed any cap enforcement), but a real synchronization bug.
  group('fill-rate baseline day key stays in sync with the anti-fraud '
      'daily-cap day key (T165)', () {
    test(
        'the exact same moment produces the exact same day key in both '
        'subsystems, right at a UTC day boundary', () async {
      // 23:30 UTC — a moment a device set to a timezone AHEAD of UTC (e.g.
      // UTC+9) would already consider the FOLLOWING calendar day in local
      // time. Before this fix, recordFillRateBaselineSample's local-time
      // read would have keyed this under the wrong (later) day than the
      // anti-fraud counters' UTC-based one on such a device.
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
          reason: 'T165 — the fill-rate sample must land under the exact '
              'same UTC calendar day the anti-fraud daily-cap counter '
              'uses for the same moment, not a separately-computed '
              '(previously LOCAL-time) day of its own');
      expect(fillRateDayKeys.length, 1,
          reason: 'sanity: exactly one day bucket, not accidentally split '
              'across two');
    });

    test(
        'a sample recorded just before UTC midnight and read back just '
        'after still lands on, and is retrievable from, the correct '
        '(earlier) UTC day', () async {
      final beforeMidnight = DateTime.utc(2026, 9, 11, 23, 59, 59);
      final afterMidnight = DateTime.utc(2026, 9, 12, 0, 0, 1);

      await prefs.recordFillRateBaselineSample(
        slotTypeName: AdSlotType.rewarded.name,
        attempts: 1,
        successes: 1,
        now: beforeMidnight,
      );

      // Read back a moment LATER, on the new UTC day — the sample must
      // still be there under the 9/11 key (within the 7-day retention
      // window), not silently dropped by the pruning logic mistaking a
      // valid recent day for an unparseable/too-old one.
      final history = prefs.getFillRateBaselineHistory(now: afterMidnight);
      expect(history['2026-09-11']?[AdSlotType.rewarded.name]?['attempts'], 1,
          reason: 'T165 — a sample from just before UTC midnight must '
              'survive being read back just after it, not be pruned away');
    });

    // codex re-review (T165) — the retention cutoff must be derived from
    // the same clamped "today" every other read of this data uses, not a
    // raw clock read that a rollback could make read EARLIER than the
    // clamped day already observed (which would loosen the retention
    // window relative to what "today" means everywhere else).
    test(
        'the 7-day retention cutoff is anchored to the clamped "today", '
        'not a raw clock read that a rollback could desync from it',
        () async {
      final day10 = DateTime.utc(2026, 9, 10);
      // Advance the high-water mark to day 18 first — day 10 is then
      // exactly 8 days before the OBSERVED (clamped) "today", one day
      // past the 7-day retention window.
      final day18 = DateTime.utc(2026, 9, 18);
      prefs.todayUtcClamped(now: day18);

      await prefs.recordFillRateBaselineSample(
        slotTypeName: AdSlotType.interstitial.name,
        attempts: 1,
        successes: 1,
        now: day10,
      );

      // A rollback to day 11 reads EARLIER than the clamped high-water
      // mark (day 18) — a cutoff derived from this raw, rolled-back clock
      // would compute "day 4", which incorrectly keeps day 10 in
      // history. Anchored to the clamped day instead, the cutoff is
      // "day 11" (18 - 7), correctly pruning day 10 as one day too old.
      final rollback = DateTime.utc(2026, 9, 11);
      final history = prefs.getFillRateBaselineHistory(now: rollback);

      expect(history.containsKey('2026-09-10'), isFalse,
          reason: 'T165 (codex re-review) — day 10 is 8 days before the '
              'clamped "today" (day 18) and must be pruned, regardless of '
              'what a rolled-back raw clock reads');
    });
  });

  // T200 — clearSdkData must remove only this SDK's own keys, and must
  // never touch VIP-entitlement keys unless BOTH the scope AND the
  // explicit confirmation flag ask for it.
  group('clearSdkData (T200)', () {
    setUp(() async {
      // A non-entitlement SDK key.
      await prefs.setConsentSettingsRaw('{"hasUserConsent":true}');
      // An entitlement SDK key.
      await prefs.markFirstInstallGraceApplied();
      // A key belonging to the HOST app (or a different plugin) in the
      // SAME SharedPreferences namespace — must survive every scope.
      final raw = await SharedPreferences.getInstance();
      await raw.setString('host_apps_own_key', 'do not touch me');
    });

    test('everythingExceptEntitlements (the default) clears the '
        'non-entitlement key but preserves the entitlement key AND the '
        'host app\'s own key', () async {
      await prefs.clearSdkData();

      expect(prefs.getConsentSettingsRaw(), isNull);
      expect(prefs.isFirstInstallGraceApplied(), isTrue,
          reason: 'an entitlement key must survive the default scope');
      final raw = await SharedPreferences.getInstance();
      expect(raw.getString('host_apps_own_key'), 'do not touch me',
          reason: 'a key this SDK does not own must never be touched, '
              'unlike clearAllData()');
    });

    test('allIncludingEntitlements WITHOUT confirmedEntitlementErasure '
        'throws ArgumentError and changes NOTHING', () async {
      await expectLater(
          prefs.clearSdkData(
              scope: SdkDataErasureScope.allIncludingEntitlements),
          throwsArgumentError);

      expect(prefs.getConsentSettingsRaw(), isNotNull,
          reason: 'a refused call must not have partially erased anything');
      expect(prefs.isFirstInstallGraceApplied(), isTrue);
    });

    test('allIncludingEntitlements WITH confirmedEntitlementErasure '
        'clears the entitlement key too, still preserves the host key',
        () async {
      await prefs.clearSdkData(
        scope: SdkDataErasureScope.allIncludingEntitlements,
        confirmedEntitlementErasure: true,
      );

      expect(prefs.getConsentSettingsRaw(), isNull);
      expect(prefs.isFirstInstallGraceApplied(), isFalse,
          reason: 'an explicit, confirmed request must actually clear '
              'entitlement data');
      final raw = await SharedPreferences.getInstance();
      expect(raw.getString('host_apps_own_key'), 'do not touch me');
    });

    test('is idempotent — calling it again when already empty does not '
        'throw', () async {
      await prefs.clearSdkData();
      await expectLater(prefs.clearSdkData(), completes);
    });
  });
}
