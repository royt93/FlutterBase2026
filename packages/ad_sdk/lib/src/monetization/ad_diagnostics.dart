import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import '../utils/sensitive_data_redactor.dart';
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
    this.pendingRevenueChecks,
    this.recentRevenueIntegrityIncidents = 0,
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

  /// T187 — `RevenueIntegrityLedger.pendingCount` (successful shows still
  /// waiting on a matching `AdRevenueEvent`), lets a dev see "why is
  /// revenue low today" in the SAME snapshot as the rest of this class
  /// instead of cross-referencing a separate ledger instance. `null` when
  /// `AdManager.enableRevenueIntegrityLedger` was never called — same
  /// "subsystem never opted in" convention as [arbitratorEstimatedEcpmMicros].
  final int? pendingRevenueChecks;

  /// T187 — count of `AdManager.incidentRecorder` entries tagged
  /// `revenue_integrity_missing:*` (the exact label
  /// `RevenueIntegrityLedger._sweepExpired` records under). Always
  /// computable from the incident recorder alone — unlike
  /// [pendingRevenueChecks], this does NOT require a live ledger to be
  /// enabled right now, since the recorder already persisted whatever a
  /// PAST ledger instance (this session or an earlier one) reported.
  /// Defaults to `0`, not nullable — an empty incident recorder legitimately
  /// means zero, not "unknown".
  final int recentRevenueIntegrityIncidents;

  Map<String, dynamic> toJson() => {
        'lastWaterfallBySlot':
            lastWaterfallBySlot.map((k, v) => MapEntry(k.name, v)),
        'fillRateBySlot': fillRateBySlot.map((k, v) => MapEntry(k.name, v)),
        'arbitratorEstimatedEcpmMicros': arbitratorEstimatedEcpmMicros,
        'arbitratorVetoRate': arbitratorVetoRate,
        'fillRateRegressionBySlot':
            fillRateRegressionBySlot.map((k, v) => MapEntry(k.name, {
                  'sessionFillRate': v.sessionFillRate,
                  'baselineFillRate': v.baselineFillRate,
                  'sessionAvgRevenueMicros': v.sessionAvgRevenueMicros,
                  'baselineAvgRevenueMicros': v.baselineAvgRevenueMicros,
                  'fillRateRegressed': v.fillRateRegressed,
                  'revenueRegressed': v.revenueRegressed,
                })),
        'pendingRevenueChecks': pendingRevenueChecks,
        'recentRevenueIntegrityIncidents': recentRevenueIntegrityIncidents,
      };

  /// Privacy-safe, bounded export for support bundles and telemetry.
  ///
  /// The payload contains diagnostics only (never preferences or event-log
  /// metadata), redacts known identifiers/credentials, and is wrapped with a
  /// schema version and SHA-256 checksum. The returned UTF-8 JSON is bounded
  /// by [maxBytes]; large waterfall arrays are deterministically truncated.
  Future<String> toSafeJsonString({int maxBytes = 65536}) async {
    if (maxBytes < 256) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be at least 256');
    }
    var truncated = false;
    final waterfalls = <String, List<String>>{};
    for (final entry in lastWaterfallBySlot.entries) {
      final values = entry.value.map((v) {
        final redacted = redactSensitiveData(v);
        final end = redacted.length > 256 ? 256 : redacted.length;
        return redacted.substring(0, end);
      }).toList(growable: false);
      final kept = values.take(64).toList(growable: false);
      if (kept.length != values.length) truncated = true;
      waterfalls[entry.key.name] = kept;
    }
    final payload = <String, dynamic>{
      'lastWaterfallBySlot': waterfalls,
      'fillRateBySlot': fillRateBySlot.map((k, v) => MapEntry(k.name, v)),
      'arbitratorEstimatedEcpmMicros': arbitratorEstimatedEcpmMicros,
      'arbitratorVetoRate': arbitratorVetoRate,
      'fillRateRegressionBySlot':
          fillRateRegressionBySlot.map((k, v) => MapEntry(k.name, {
                'sessionFillRate': v.sessionFillRate,
                'baselineFillRate': v.baselineFillRate,
                'sessionAvgRevenueMicros': v.sessionAvgRevenueMicros,
                'baselineAvgRevenueMicros': v.baselineAvgRevenueMicros,
                'fillRateRegressed': v.fillRateRegressed,
                'revenueRegressed': v.revenueRegressed,
              })),
      'pendingRevenueChecks': pendingRevenueChecks,
      'recentRevenueIntegrityIncidents': recentRevenueIntegrityIncidents,
    };
    var payloadJson = jsonEncode(payload);
    while (utf8.encode(payloadJson).length > maxBytes ~/ 2 &&
        waterfalls.isNotEmpty) {
      final key = waterfalls.keys.last;
      final list = waterfalls[key]!;
      if (list.length <= 1) {
        waterfalls.remove(key);
      } else {
        waterfalls[key] = list.take((list.length / 2).ceil()).toList();
      }
      truncated = true;
      payloadJson = jsonEncode(payload);
    }
    final digest = await Sha256().hash(utf8.encode(payloadJson));
    final envelope = {
      'schemaVersion': 1,
      'truncated': truncated,
      'payload': payload,
      'sha256': base64Url.encode(digest.bytes),
    };
    var encoded = jsonEncode(envelope);
    if (utf8.encode(encoded).length > maxBytes) {
      final minimal = {
        'schemaVersion': 1,
        'truncated': true,
        'payload': {'lastWaterfallBySlot': <String, dynamic>{}},
      };
      final minimalJson = jsonEncode(minimal['payload']);
      final minimalDigest = await Sha256().hash(utf8.encode(minimalJson));
      encoded = jsonEncode(
          {...minimal, 'sha256': base64Url.encode(minimalDigest.bytes)});
    }
    return encoded;
  }

  /// Verifies the checksum of a string produced by [toSafeJsonString].
  static Future<bool> verifySafeJsonString(String encoded) async {
    try {
      final envelope = jsonDecode(encoded) as Map<String, dynamic>;
      final payload = envelope['payload'];
      final expected = envelope['sha256'];
      if (payload is! Map || expected is! String) return false;
      final digest = await Sha256().hash(utf8.encode(jsonEncode(payload)));
      return base64Url.encode(digest.bytes) == expected;
    } catch (_) {
      return false;
    }
  }

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
      SafeLogger.w(
          'AdDiagnostics',
          'lastWaterfallBySlotFrom: skipped $skipped malformed compliance-log '
              'entr${skipped == 1 ? 'y' : 'ies'} (missing/unrecognised slotType)');
    }
    return waterfalls;
  }
}
