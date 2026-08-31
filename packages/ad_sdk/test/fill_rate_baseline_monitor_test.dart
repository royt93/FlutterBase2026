// T97 — Flagship: per-device fill-rate/eCPM 7-day baseline regression
// detector. Driven purely through AdManager().debugEmit(...) — no
// adapter/native plugin needed, same convention as fill_rate_monitor_test.dart.
//
// Historical baseline days are seeded directly into the mocked
// SharedPreferences blob (bypassing recordFillRateBaselineSample, which only
// ever writes to TODAY) so tests can control what "yesterday" looked like
// without manipulating the clock.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _historyKey = 'ad_sdk_fill_rate_baseline_history_v1';

AdLoadEvent _load(AdSlotType type, bool success) => AdLoadEvent(
      providerTag: 'fake',
      type: type,
      placement: AdPlacement.unspecified,
      success: success,
    );

AdRevenueEvent _revenue(AdSlotType type, int valueMicros) => AdRevenueEvent(
      providerTag: 'fake',
      type: type,
      placement: AdPlacement.unspecified,
      valueMicros: valueMicros,
      currencyCode: 'USD',
    );

String _daysAgo(int n) =>
    DateTime.now().subtract(Duration(days: n)).toIso8601String().substring(0, 10);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FillRateBaselineMonitor monitor;
  late AdPreferences prefs;

  /// Seeds a past day's {attempts, successes, revenueMicros, revenueCount}
  /// for [type] directly into the mocked blob — never today's date, so it's
  /// always eligible as baseline history.
  Future<void> seedPastDay(
    AdSlotType type, {
    required int daysAgo,
    int attempts = 0,
    int successes = 0,
    int revenueMicros = 0,
    int revenueCount = 0,
  }) async {
    final raw = await SharedPreferences.getInstance();
    final existing = raw.getString(_historyKey);
    final history = existing == null
        ? <String, dynamic>{}
        : jsonDecode(existing) as Map<String, dynamic>;
    final date = _daysAgo(daysAgo);
    final perType = (history[date] as Map<String, dynamic>?) ?? {};
    perType[type.name] = {
      'attempts': attempts,
      'successes': successes,
      'revenueMicros': revenueMicros,
      'revenueCount': revenueCount,
    };
    history[date] = perType;
    await raw.setString(_historyKey, jsonEncode(history));
  }

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  tearDown(() => monitor.dispose());

  test('no alert when there is no baseline history yet', () async {
    monitor = FillRateBaselineMonitor(prefs, minSamples: 3);
    for (var i = 0; i < 5; i++) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
    }
    await Future<void>.delayed(Duration.zero);
    expect(monitor.activeAlerts, isEmpty);
  });

  test('no alert while session sample count is below minSamples', () async {
    await seedPastDay(AdSlotType.interstitial,
        daysAgo: 1, attempts: 100, successes: 90);
    monitor = FillRateBaselineMonitor(prefs, minSamples: 10);
    for (var i = 0; i < 3; i++) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
    }
    await Future<void>.delayed(Duration.zero);
    expect(monitor.activeAlerts, isEmpty);
  });

  test(
      'fires a fill-rate regression alert when session rate is well below '
      'the 7-day baseline', () async {
    // Baseline: 90% fill rate (90/100) over the last couple of days.
    await seedPastDay(AdSlotType.interstitial,
        daysAgo: 1, attempts: 60, successes: 54);
    await seedPastDay(AdSlotType.interstitial,
        daysAgo: 2, attempts: 40, successes: 36);

    monitor = FillRateBaselineMonitor(prefs, minSamples: 5);
    // Session: 20% fill rate (1/5).
    for (final ok in [true, false, false, false, false]) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, ok));
    }
    await Future<void>.delayed(Duration.zero);

    expect(monitor.activeAlerts.containsKey(AdSlotType.interstitial), isTrue);
    final alert = monitor.activeAlerts[AdSlotType.interstitial]!;
    expect(alert.fillRateRegressed, isTrue);
    expect(alert.sessionFillRate, closeTo(0.2, 0.001));
    expect(alert.baselineFillRate, closeTo(0.9, 0.001));
  });

  test('does not alert when the session rate is within threshold of baseline',
      () async {
    await seedPastDay(AdSlotType.interstitial,
        daysAgo: 1, attempts: 100, successes: 90); // 90% baseline

    monitor = FillRateBaselineMonitor(prefs,
        regressionThreshold: 0.2, minSamples: 5);
    // Session: 80% fill rate — an 11% relative drop, under the 20% threshold.
    for (final ok in [true, true, true, true, false]) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, ok));
    }
    await Future<void>.delayed(Duration.zero);

    expect(monitor.activeAlerts, isEmpty);
  });

  test('detects a revenue regression independent of fill rate', () async {
    await seedPastDay(AdSlotType.rewarded,
        daysAgo: 1,
        attempts: 20,
        successes: 20,
        revenueMicros: 20 * 1000000,
        revenueCount: 20); // avg 1,000,000 micros/ad baseline

    monitor = FillRateBaselineMonitor(prefs, minSamples: 5);
    for (var i = 0; i < 5; i++) {
      AdManager().debugEmit(_load(AdSlotType.rewarded, true)); // 100% fill
      AdManager()
          .debugEmit(_revenue(AdSlotType.rewarded, 100000)); // far below baseline
    }
    await Future<void>.delayed(Duration.zero);

    final alert = monitor.activeAlerts[AdSlotType.rewarded]!;
    expect(alert.revenueRegressed, isTrue);
    expect(alert.fillRateRegressed, isFalse);
  });

  test("today's own persisted writes are never used as their own baseline",
      () async {
    monitor = FillRateBaselineMonitor(prefs, minSamples: 3);
    // Emit a lot of session activity — this also persists into TODAY's
    // bucket via recordFillRateBaselineSample, but that must never be read
    // back as "baseline" for the very same session.
    for (var i = 0; i < 20; i++) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, i.isEven));
    }
    await Future<void>.delayed(Duration.zero);

    expect(monitor.activeAlerts, isEmpty,
        reason:
            'no other day has data yet, so there is no baseline to compare '
            'against regardless of how much the session itself wrote');
  });

  test('alerts stream fires once, stays quiet while regression persists, '
      'fires again after a recovery + new drop', () async {
    await seedPastDay(AdSlotType.interstitial,
        daysAgo: 1, attempts: 100, successes: 90);

    monitor = FillRateBaselineMonitor(prefs, minSamples: 5);
    final fired = <FillRateRegressionAlert>[];
    monitor.alerts.listen(fired.add);

    // Drop below baseline.
    for (final ok in [true, false, false, false, false]) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, ok));
    }
    await Future<void>.delayed(Duration.zero);
    expect(fired, hasLength(1));

    // Still regressed — must not fire again.
    AdManager().debugEmit(_load(AdSlotType.interstitial, false));
    await Future<void>.delayed(Duration.zero);
    expect(fired, hasLength(1));

    // Recover with a large burst of successes. The session tally is
    // cumulative for the monitor's lifetime (a "session" is the whole app
    // run, matching the ticket's "so sánh phiên hiện tại" intent) — so
    // pulling a diluted average back above threshold takes proportionally
    // more good samples than the handful that caused the initial dip.
    for (var i = 0; i < 200; i++) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, true));
    }
    await Future<void>.delayed(Duration.zero);
    expect(monitor.activeAlerts, isEmpty);

    // Drag the cumulative average back down with enough failures.
    for (var i = 0; i < 100; i++) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
    }
    await Future<void>.delayed(Duration.zero);
    expect(fired, hasLength(2));
  });

  test('each slot type is tracked independently', () async {
    await seedPastDay(AdSlotType.interstitial,
        daysAgo: 1, attempts: 100, successes: 90);
    await seedPastDay(AdSlotType.rewarded,
        daysAgo: 1, attempts: 100, successes: 90);

    monitor = FillRateBaselineMonitor(prefs, minSamples: 5);
    for (final ok in [true, false, false, false, false]) {
      AdManager().debugEmit(_load(AdSlotType.interstitial, ok));
    }
    for (var i = 0; i < 5; i++) {
      AdManager().debugEmit(_load(AdSlotType.rewarded, true));
    }
    await Future<void>.delayed(Duration.zero);

    expect(monitor.activeAlerts.containsKey(AdSlotType.interstitial), isTrue);
    expect(monitor.activeAlerts.containsKey(AdSlotType.rewarded), isFalse);
  });

  test(
      'T101: two samples fired back-to-back (no await between them) both '
      'land — neither delta is lost to a lost-update race', () async {
    monitor = FillRateBaselineMonitor(prefs, minSamples: 1);
    // The real bug only shows up against genuine async I/O latency — the
    // in-memory SharedPreferences mock used here resolves fast enough that
    // it never naturally exhibits the race. This debug hook reproduces the
    // same timing gap deterministically instead of relying on `sleep`/flake.
    AdPreferences.debugFillRateWriteDelay =
        const Duration(milliseconds: 20);
    addTearDown(() => AdPreferences.debugFillRateWriteDelay = null);

    // Fired without awaiting either individually: both read-modify-write
    // cycles start before either has written back, which is exactly the
    // race T101 describes. The write-chain in AdPreferences must still
    // serialize them so both deltas end up persisted.
    final f1 = prefs.recordFillRateBaselineSample(
        slotTypeName: AdSlotType.interstitial.name, attempts: 1, successes: 1);
    final f2 = prefs.recordFillRateBaselineSample(
        slotTypeName: AdSlotType.rewarded.name, attempts: 1, successes: 0);
    await f1;
    await f2;

    final today = DateTime.now().toIso8601String().substring(0, 10);
    final todayHistory = prefs.getFillRateBaselineHistory()[today];
    expect(todayHistory?[AdSlotType.interstitial.name]?['attempts'], 1,
        reason: 'the first sample must not be discarded by the second');
    expect(todayHistory?[AdSlotType.rewarded.name]?['attempts'], 1,
        reason: 'the second sample must not be discarded either');
  });
}
