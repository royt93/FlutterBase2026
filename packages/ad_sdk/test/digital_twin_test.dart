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

Map<String, dynamic> _revenueForSlot(
        int timestampMs, int valueMicros, String slotType) =>
    {
      'kind': 'ad_event',
      'timestampMs': timestampMs,
      'eventType': 'AdRevenueEvent',
      'slotType': slotType,
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

  group('T177 audit fix — hypotheticalDailyCap contract', () {
    test('a negative cap throws in debug mode instead of silently meaning '
        '"uncapped"', () {
      final twin = MonetizationDigitalTwin([
        _show(day1, revenueMicros: 1000000),
        _revenue(day1, 1000000),
      ]);

      expect(() => twin.forecastDailyCap(-1), throwsA(isA<AssertionError>()));
    });

    test('a cap of 0 forecasts zero impressions/revenue for every day — a '
        'valid input, not a special "uncapped" case', () {
      final twin = MonetizationDigitalTwin([
        _show(day1, revenueMicros: 1000000),
        _revenue(day1, 1000000),
        _dailyCapSkip(day1),
      ]);

      final forecast = twin.forecastDailyCap(0);
      expect(forecast.meanDailyImpressions, 0);
      expect(forecast.meanDailyRevenueMicros, 0);
      expect(forecast.meanBlockedRequestsRemaining, 2,
          reason: 'demand of 2 (1 shown + 1 blocked), none of it let '
              'through at cap 0');
    });
  });

  test('AdManager().buildMonetizationDigitalTwin() is null before any '
      'event log exists, non-null once one does', () {
    AdManager().debugEventLog = null;
    expect(AdManager().buildMonetizationDigitalTwin(), isNull);
  });

  group('round 60 audit fix — non-fullscreen revenue excluded', () {
    // This twin exists only to forecast the ONE fullscreen daily-cap axis
    // (see the class doc comment) — `avgRevenuePerShow` divides revenue by
    // `shown`, which only ever counts fullscreen `AdShowEvent`s (banner/
    // mrec/native never emit one). Revenue from those formats must be
    // excluded too, or the average is diluted by impressions that were
    // never eligible for the cap being forecast.
    test('banner/mrec/native AdRevenueEvent is not counted toward the day\'s '
        'revenue used by forecastDailyCap', () {
      final twin = MonetizationDigitalTwin([
        _show(day1, revenueMicros: 1000000),
        _revenueForSlot(day1, 2000000, 'interstitial'),
        _revenueForSlot(day1, 50000000, 'banner'),
        _revenueForSlot(day1, 50000000, 'mrec'),
        _revenueForSlot(day1, 50000000, 'native'),
      ]);

      final forecast = twin.forecastDailyCap(1);
      expect(forecast.meanDailyRevenueMicros, 2000000,
          reason: 'only the interstitial revenue paired with the one '
              'fullscreen impression should count — banner/mrec/native '
              'revenue must not dilute avgRevenuePerShow');
    });

    test('appOpen/rewarded/rewardedInterstitial revenue IS counted (all '
        'fullscreen formats, not just interstitial)', () {
      final twin = MonetizationDigitalTwin([
        _show(day1, revenueMicros: 1000000),
        _revenueForSlot(day1, 1000000, 'appOpen'),
        _revenueForSlot(day1, 1000000, 'rewarded'),
        _revenueForSlot(day1, 1000000, 'rewardedInterstitial'),
      ]);

      final forecast = twin.forecastDailyCap(1);
      expect(forecast.meanDailyRevenueMicros, 3000000);
    });
  });
}
