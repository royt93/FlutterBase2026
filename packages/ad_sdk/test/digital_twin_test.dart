// T129 — Monetization Digital Twin v0 (daily-cap axis only, see the class
// doc in lib/src/monetization/digital_twin.dart for the deliberate rescope
// from the full 5-axis ticket). Pure arithmetic over the same JSON shape
// AdEventLog.recordEvent produces — no AdManager/AdEventLog instance needed.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _show(int timestampMs, {int revenueMicros = 0}) => {
      'kind': 'ad_event',
      'timestampMs': timestampMs,
      'eventType': 'AdShowEvent',
      'slotType': 'interstitial',
      'success': true,
    };

Map<String, dynamic> _revenue(int timestampMs, int valueMicros) => {
      'kind': 'ad_event',
      'timestampMs': timestampMs,
      'eventType': 'AdRevenueEvent',
      'slotType': 'interstitial',
      'valueMicros': valueMicros,
    };

Map<String, dynamic> _dailyCapSkip(int timestampMs) => {
      'kind': 'ad_event',
      'timestampMs': timestampMs,
      'eventType': 'AdSkipEvent',
      'slotType': 'interstitial',
      'reason': 'daily_cap',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final day1 = DateTime(2026, 1, 1, 10).millisecondsSinceEpoch;
  final day1Later = DateTime(2026, 1, 1, 20).millisecondsSinceEpoch;
  final day2 = DateTime(2026, 1, 2, 10).millisecondsSinceEpoch;

  test('groups entries by calendar day, ignoring non-ad_event kinds', () {
    final twin = MonetizationDigitalTwin([
      _show(day1, revenueMicros: 1000000),
      _revenue(day1, 1000000),
      _show(day1Later, revenueMicros: 1000000),
      _revenue(day1Later, 1000000),
      _show(day2, revenueMicros: 2000000),
      _revenue(day2, 2000000),
      {'kind': 'safety_block', 'timestampMs': day1, 'reason': 'ctr'},
    ]);

    final outcomes = twin.actualDailyOutcomes;
    expect(outcomes, hasLength(2));
    expect(outcomes[0].dayKey, '2026-01-01');
    expect(outcomes[0].shown, 2);
    expect(outcomes[0].revenueMicros, 2000000);
    expect(outcomes[1].dayKey, '2026-01-02');
    expect(outcomes[1].shown, 1);
  });

  test('no history → forecast is all zeros, not an error', () {
    final twin = MonetizationDigitalTwin(const []);
    final forecast = twin.forecastDailyCap(10);
    expect(forecast.daysObserved, 0);
    expect(forecast.meanDailyImpressions, 0);
    expect(forecast.meanDailyRevenueMicros, 0);
  });

  test(
      'raising the cap above actual demand recovers the full blocked amount, '
      'valued at that day\'s own average revenue-per-show', () {
    // Day 1: cap was 2 → 2 shown, 3 more blocked by daily_cap (demand = 5),
    // each shown ad averaged 1_000_000 micros.
    final twin = MonetizationDigitalTwin([
      _show(day1, revenueMicros: 1000000),
      _revenue(day1, 1000000),
      _show(day1Later, revenueMicros: 1000000),
      _revenue(day1Later, 1000000),
      _dailyCapSkip(day1),
      _dailyCapSkip(day1),
      _dailyCapSkip(day1),
    ]);

    final atActualCap = twin.forecastDailyCap(2);
    expect(atActualCap.meanDailyImpressions, 2);
    expect(atActualCap.meanDailyRevenueMicros, 2000000);
    expect(atActualCap.meanBlockedRequestsRemaining, 3,
        reason: 'at the same cap that was actually active, nothing changes');

    final raisedCap = twin.forecastDailyCap(10);
    expect(raisedCap.meanDailyImpressions, 5,
        reason: 'cap of 10 exceeds the day\'s full demand of 5 (2 shown + 3 '
            'blocked) — all 5 would have gone through');
    expect(raisedCap.meanDailyRevenueMicros, 5000000,
        reason: '5 impressions * 1_000_000 avg revenue-per-show');
    expect(raisedCap.meanBlockedRequestsRemaining, 0);
  });

  test('lowering the cap below actual shown count reduces the forecast',
      () {
    final twin = MonetizationDigitalTwin([
      _show(day1, revenueMicros: 1000000),
      _revenue(day1, 1000000),
      _show(day1Later, revenueMicros: 1000000),
      _revenue(day1Later, 1000000),
    ]);

    final forecast = twin.forecastDailyCap(1);
    expect(forecast.meanDailyImpressions, 1);
    expect(forecast.meanDailyRevenueMicros, 1000000);
  });

  test('AdManager().buildMonetizationDigitalTwin() is null before any '
      'event log exists, non-null once one does', () {
    AdManager().debugEventLog = null;
    expect(AdManager().buildMonetizationDigitalTwin(), isNull);
  });
}
