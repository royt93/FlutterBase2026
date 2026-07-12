import 'dart:convert';

import '../adaptive/adaptive_frequency.dart';
import '../state/ad_event.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';

/// Rolling, persisted log of everything relevant to a compliance audit:
/// every [AdEvent] emitted on `AdManager().events`, plus safety-cap block
/// reasons (which never reach the event stream). Backs T23's
/// `AdManager.exportComplianceReport()`.
///
/// Capped at [maxEntries] (oldest dropped first) so it can't grow unbounded
/// on a long-lived install. Persisted as JSON via [AdPreferences] — no new
/// storage dependency.
class AdEventLog {
  AdEventLog(this._prefs, {int maxEntries = 5000}) : _maxEntries = maxEntries {
    _load();
  }

  static const String _tag = 'AdEventLog';

  final AdPreferences _prefs;
  final int _maxEntries;
  final List<Map<String, dynamic>> _entries = [];

  /// Chains every [_persist] call after the previous one so concurrent
  /// `_append`s can't race their `setString` writes and finish out of
  /// order — each persist always encodes the latest [_entries] snapshot.
  Future<void> _persistChain = Future.value();

  /// Read-only view of every log entry, oldest first.
  List<Map<String, dynamic>> get entries => List.unmodifiable(_entries);

  void _load() {
    final raw = _prefs.getComplianceLogRaw();
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List;
      // Drop entries missing a valid `timestampMs` here at load time — every
      // reader (inRange, export) assumes `e['timestampMs'] as int` and would
      // otherwise throw much later, far from the actual corrupt data.
      _entries.addAll(decoded
          .cast<Map<String, dynamic>>()
          .where((e) => e['timestampMs'] is int));
    } catch (e) {
      SafeLogger.w(_tag, 'discarding corrupt persisted compliance log: $e');
    }
  }

  void recordEvent(AdEvent event, {int? timestampMs}) {
    _append({
      'kind': 'ad_event',
      'timestampMs': timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      'eventType': event.runtimeType.toString(),
      'providerTag': event.providerTag,
      'slotType': event.type.name,
      'placement': event.placement.id,
      ..._eventExtra(event),
    });
  }

  void recordSafetyBlock(String reason, {int? timestampMs}) {
    _append({
      'kind': 'safety_block',
      'timestampMs': timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      'reason': reason,
    });
  }

  /// T26 Phase 1 — records an [AdaptiveFrequencySignal] as a diagnostic
  /// entry, viewable via the same compliance export as everything else here.
  void recordAdaptiveSignal(AdaptiveFrequencySignal signal) {
    _append({
      'kind': 'adaptive_signal',
      'timestampMs': signal.timestampMs,
      'signalKind': signal.kind,
      'gapMs': signal.gapMs,
    });
  }

  void _append(Map<String, dynamic> entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _schedulePersist();
  }

  void _schedulePersist() {
    _persistChain = _persistChain.then((_) => _persist()).catchError((e) {
      SafeLogger.w(_tag, 'compliance log persist failed: $e');
    });
  }

  Future<void> _persist() => _prefs.setComplianceLogRaw(jsonEncode(_entries));

  /// Entries with `timestampMs` inside `[from, to]` (inclusive). Null bounds
  /// are open-ended.
  List<Map<String, dynamic>> inRange({DateTime? from, DateTime? to}) {
    if (from == null && to == null) return entries;
    final fromMs = from?.millisecondsSinceEpoch ?? 0;
    final toMs = to?.millisecondsSinceEpoch ?? (1 << 62);
    return _entries.where((e) {
      final ts = e['timestampMs'] as int;
      return ts >= fromMs && ts <= toMs;
    }).toList(growable: false);
  }

  Future<void> clear() async {
    _entries.clear();
    _schedulePersist();
    await _persistChain;
  }
}

Map<String, dynamic> _eventExtra(AdEvent event) => switch (event) {
      AdLoadEvent e => {'success': e.success, 'errorCode': e.errorCode},
      AdShowEvent e => {'success': e.success},
      AdClickEvent _ => const {},
      AdRewardEvent e => {'label': e.label, 'amount': e.amount},
      AdRevenueEvent e => {
          'valueMicros': e.valueMicros,
          'currencyCode': e.currencyCode,
          'networkName': e.networkName,
          'precision': e.precision,
        },
      AdAnomalyEvent e => {
          'reason': e.reason,
          'violationCount': e.violationCount,
          'pauseDurationMs': e.pauseDurationMs,
        },
      ArbitratorNudgeEvent e => {
          'estimatedEcpmMicros': e.estimatedEcpmMicros,
        },
    };
