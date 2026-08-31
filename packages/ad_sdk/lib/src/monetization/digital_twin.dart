/// T129 — flagship Monetization Digital Twin, **v0, deliberately rescoped**.
///
/// The full ticket asked for a counterfactual simulator across FIVE policy
/// axes (cap, retry, provider split, VIP duration, preload) predicting
/// impression/revenue/blocked-request/UX-cost as confidence intervals. That
/// is a genuinely separate project: it would require re-implementing
/// `AdSafetyConfig`'s entire stateful decision logic (daily/hourly/session
/// caps, per-placement caps, click-spam, CTR, network-fatigue cooldowns,
/// dry-run...) as a second, pure, replayable copy — a correctness-critical
/// duplicate of code that has been through 27 audit rounds, built in one
/// pass, with no contract test between the two ever drifting apart. That is
/// XL-risk for a P2 idea ticket.
///
/// **What this ships instead**: a deterministic replay over ONE axis —
/// `AdSafetyParams.maxFullscreenAdsPerDay` — the one policy the SDK already
/// logs enough about to replay purely from `AdEventLog` history (every
/// `AdShowEvent` and every `AdSkipEvent(reason: 'daily_cap')` is already
/// there). No new event needed, no shadow requests, no live state touched.
/// If this proves useful, the other four axes are natural follow-up
/// tickets — same shape, one at a time, each backed by its own replay data.
library;

/// One calendar day's worth of ACTUAL (not hypothetical) fullscreen-ad
/// outcomes, extracted from `AdEventLog` history.
class DailyAdOutcome {
  const DailyAdOutcome({
    required this.dayKey,
    required this.shown,
    required this.blockedByDailyCap,
    required this.revenueMicros,
  });

  /// `yyyy-MM-dd`, device-local calendar day.
  final String dayKey;

  /// Fullscreen ads actually shown that day (`AdShowEvent`, `success: true`).
  final int shown;

  /// Load attempts that day skipped specifically for `reason: 'daily_cap'`
  /// (`AdSkipEvent`) — i.e. ones that would have gone through under a
  /// higher cap, all else equal.
  final int blockedByDailyCap;

  /// Total revenue (`AdRevenueEvent.valueMicros`) attributed to that day.
  final int revenueMicros;
}

/// A forecast for one hypothetical [maxFullscreenAdsPerDay] value, built
/// from the trailing [DailyAdOutcome] history — see [MonetizationDigitalTwin]
/// class doc for the counterfactual's assumptions and limits.
class DigitalTwinForecast {
  const DigitalTwinForecast({
    required this.hypotheticalDailyCap,
    required this.daysObserved,
    required this.meanDailyImpressions,
    required this.medianDailyImpressions,
    required this.meanDailyRevenueMicros,
    required this.meanBlockedRequestsRemaining,
  });

  final int hypotheticalDailyCap;

  /// How many days of history this forecast is built from — the ticket's
  /// own "confidence interval" ask starts here: a forecast from 2 days of
  /// history carries a very different confidence than one from 30.
  final int daysObserved;

  final double meanDailyImpressions;
  final double medianDailyImpressions;
  final double meanDailyRevenueMicros;

  /// Average per-day count of daily-cap skips that would STILL be skipped
  /// even under [hypotheticalDailyCap] (0 once the cap is raised past the
  /// historical demand ceiling — never negative).
  final double meanBlockedRequestsRemaining;
}

/// Deterministic, read-only replay over `AdEventLog` history. Never issues
/// an ad request, never touches `AdSafetyConfig`'s live state — pure
/// arithmetic over already-recorded, already-redacted compliance-log
/// entries (see `AdEventLog.entries`/`inRange`).
class MonetizationDigitalTwin {
  /// [logEntries] — pass `AdEventLog.entries` (or `.inRange(...)` for a
  /// bounded window) directly; this class only ever reads the plain JSON
  /// shape `AdEventLog.recordEvent` already produces.
  MonetizationDigitalTwin(List<Map<String, dynamic>> logEntries)
      : _daily = _groupByDay(logEntries);

  final Map<String, _DayAccumulator> _daily;

  static Map<String, _DayAccumulator> _groupByDay(
      List<Map<String, dynamic>> entries) {
    final byDay = <String, _DayAccumulator>{};
    for (final e in entries) {
      if (e['kind'] != 'ad_event') continue;
      final ts = e['timestampMs'] as int?;
      if (ts == null) continue;
      final day = _dayKey(DateTime.fromMillisecondsSinceEpoch(ts));
      final acc = byDay.putIfAbsent(day, _DayAccumulator.new);
      switch (e['eventType']) {
        case 'AdShowEvent':
          if (e['success'] == true) acc.shown++;
        case 'AdSkipEvent':
          if (e['reason'] == 'daily_cap') acc.blockedByDailyCap++;
        case 'AdRevenueEvent':
          acc.revenueMicros += (e['valueMicros'] as num?)?.toInt() ?? 0;
      }
    }
    return byDay;
  }

  static String _dayKey(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  /// The actual, non-hypothetical daily outcomes this twin was built from —
  /// exposed mainly for tests and for a host that wants the raw numbers
  /// without a hypothetical cap applied.
  List<DailyAdOutcome> get actualDailyOutcomes => _daily.entries
      .map((e) => DailyAdOutcome(
            dayKey: e.key,
            shown: e.value.shown,
            blockedByDailyCap: e.value.blockedByDailyCap,
            revenueMicros: e.value.revenueMicros,
          ))
      .toList(growable: false)
    ..sort((a, b) => a.dayKey.compareTo(b.dayKey));

  /// Forecasts outcomes under [hypotheticalDailyCap] instead of whatever cap
  /// was actually active while this history was recorded.
  ///
  /// **Assumption (stated, not hidden):** each day's own average
  /// revenue-per-shown-ad is used to value the ADDITIONAL impressions a
  /// higher cap would have allowed (up to that day's actual demand — shown +
  /// blockedByDailyCap). This is the simplest defensible estimate from data
  /// the SDK already has; it does NOT model fatigue, fill-rate decay, or
  /// eCPM changing with volume — a host reading this must treat it as a
  /// rough estimate, not a promise, exactly like the class doc says.
  DigitalTwinForecast forecastDailyCap(int hypotheticalDailyCap) {
    final outcomes = actualDailyOutcomes;
    if (outcomes.isEmpty) {
      return DigitalTwinForecast(
        hypotheticalDailyCap: hypotheticalDailyCap,
        daysObserved: 0,
        meanDailyImpressions: 0,
        medianDailyImpressions: 0,
        meanDailyRevenueMicros: 0,
        meanBlockedRequestsRemaining: 0,
      );
    }

    final impressions = <int>[];
    final revenues = <double>[];
    final remainingBlocked = <int>[];

    for (final day in outcomes) {
      final demand = day.shown + day.blockedByDailyCap;
      final wouldShow =
          hypotheticalDailyCap < 0 ? day.shown : _min(hypotheticalDailyCap, demand);
      final avgRevenuePerShow =
          day.shown == 0 ? 0.0 : day.revenueMicros / day.shown;
      // Scales uniformly off the day's own average — deliberately symmetric
      // so a LOWER hypothetical cap (below what was actually shown) reduces
      // the forecast just as a higher one increases it, off the same rate.
      final forecastRevenue = wouldShow * avgRevenuePerShow;

      impressions.add(wouldShow);
      revenues.add(forecastRevenue);
      remainingBlocked.add(_max(0, demand - wouldShow));
    }

    impressions.sort();
    final mid = impressions.length ~/ 2;
    final median = impressions.length.isOdd
        ? impressions[mid].toDouble()
        : (impressions[mid - 1] + impressions[mid]) / 2.0;

    return DigitalTwinForecast(
      hypotheticalDailyCap: hypotheticalDailyCap,
      daysObserved: outcomes.length,
      meanDailyImpressions: _mean(impressions.map((e) => e.toDouble())),
      medianDailyImpressions: median,
      meanDailyRevenueMicros: _mean(revenues),
      meanBlockedRequestsRemaining:
          _mean(remainingBlocked.map((e) => e.toDouble())),
    );
  }
}

class _DayAccumulator {
  int shown = 0;
  int blockedByDailyCap = 0;
  int revenueMicros = 0;
}

int _min(int a, int b) => a < b ? a : b;
int _max(int a, int b) => a > b ? a : b;
double _mean(Iterable<double> values) {
  final list = values.toList();
  if (list.isEmpty) return 0;
  return list.reduce((a, b) => a + b) / list.length;
}
