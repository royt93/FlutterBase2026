import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'fill_rate_baseline_monitor.dart';

/// One-shot snapshot combining the monetization signals that otherwise live
/// in separate opt-in subsystems — mediation waterfall, fill rate, 7-day
/// baseline regressions, and arbitrator veto stats — so a partner can answer
/// "why is eCPM low today" without cross-referencing several different
/// pages. Built by `AdManager.diagnostics()`.
class AdDiagnostics {
  const AdDiagnostics({
    required this.lastWaterfallBySlot,
    required this.fillRateBySlot,
    this.arbitratorEstimatedEcpmMicros,
    this.arbitratorVetoRate,
    this.fillRateRegressionBySlot = const {},
  });

  /// Most recent `AdRevenueEvent.mediationWaterfall` seen per slot (from the
  /// persisted compliance log). A slot is absent if no revenue event ever
  /// carried waterfall data for it.
  final Map<AdSlotType, List<String>> lastWaterfallBySlot;

  /// `FillRateMonitor.fillRate` per slot type. Empty map if
  /// `AdManager.fillRateMonitor` is disabled (not just zero-filled) — check
  /// `.isEmpty` to distinguish "monitor off" from "monitor on, no data yet".
  final Map<AdSlotType, double> fillRateBySlot;

  /// `null` if `AdManager.arbitrator` is disabled.
  final int? arbitratorEstimatedEcpmMicros;

  /// `null` if `AdManager.arbitrator` is disabled.
  final double? arbitratorVetoRate;

  /// T97 — active fill-rate/eCPM regression alerts vs. this device's own
  /// trailing 7-day baseline, keyed by slot. Empty if
  /// `AdManager.fillRateBaselineMonitor` is disabled OR nothing is currently
  /// regressed.
  final Map<AdSlotType, FillRateRegressionAlert> fillRateRegressionBySlot;

  Map<String, dynamic> toJson() => {
        'lastWaterfallBySlot':
            lastWaterfallBySlot.map((k, v) => MapEntry(k.name, v)),
        'fillRateBySlot': fillRateBySlot.map((k, v) => MapEntry(k.name, v)),
        'arbitratorEstimatedEcpmMicros': arbitratorEstimatedEcpmMicros,
        'arbitratorVetoRate': arbitratorVetoRate,
        'fillRateRegressionBySlot': fillRateRegressionBySlot.map((k, v) =>
            MapEntry(k.name, {
              'sessionFillRate': v.sessionFillRate,
              'baselineFillRate': v.baselineFillRate,
              'sessionAvgRevenueMicros': v.sessionAvgRevenueMicros,
              'baselineAvgRevenueMicros': v.baselineAvgRevenueMicros,
              'fillRateRegressed': v.fillRateRegressed,
              'revenueRegressed': v.revenueRegressed,
            })),
      };

  /// Pure indexing helper — the most recent `AdRevenueEvent.mediationWaterfall`
  /// per slot from a list of persisted event-log entries (oldest-first, same
  /// shape as `AdEventLog.entries`). Exposed statically (mirrors
  /// `ComplianceReport.generate`'s raw-`events` param) so it's unit-testable
  /// without a live `AdEventLog`/`SharedPreferences`.
  static Map<AdSlotType, List<String>> lastWaterfallBySlotFrom(
      List<Map<String, dynamic>> entries) {
    final waterfalls = <AdSlotType, List<String>>{};
    var skipped = 0;
    for (final e in entries) {
      if (e['eventType'] != 'AdRevenueEvent') continue;
      final waterfall = e['mediationWaterfall'];
      if (waterfall is! List) continue;
      // T151 — this persisted compliance-log entry can outlive an SDK
      // version (a renamed/removed slotType), be corrupted, or have a
      // field edited by hand. AdSlotType.values.byName() used to throw on
      // any of that, crashing the whole diagnostics() call for every
      // caller over one bad entry — every other reader of this same log
      // (ad_event_log.dart's own _load(), WaterfallTuner's
      // _Key.tryParse) already skips a malformed entry instead. Same
      // fix here: skip, don't throw.
      final slotTypeName = e['slotType'];
      if (slotTypeName is! String) {
        skipped++;
        continue;
      }
      AdSlotType? slot;
      for (final candidate in AdSlotType.values) {
        if (candidate.name == slotTypeName) {
          slot = candidate;
          break;
        }
      }
      if (slot == null) {
        skipped++;
        continue;
      }
      waterfalls[slot] = waterfall.cast<String>();
    }
    if (skipped > 0) {
      SafeLogger.w('AdDiagnostics',
          'lastWaterfallBySlotFrom: skipped $skipped malformed compliance-log '
          'entr${skipped == 1 ? 'y' : 'ies'} (missing/unrecognised slotType)');
    }
    return waterfalls;
  }
}
