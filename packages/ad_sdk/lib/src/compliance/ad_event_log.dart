import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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

  /// T70 — debounces the actual disk write: rapid successive events (e.g. a
  /// burst of impression/click/revenue events) reset this timer instead of
  /// each triggering their own `jsonEncode` + `setString` of the whole
  /// (up to [_maxEntries]-sized) log. [flush] forces an immediate write —
  /// call it before anything that could kill the process (app backgrounding).
  static const Duration _debounceWindow = Duration(seconds: 1);
  Timer? _debounceTimer;

  /// Read-only view of every log entry, oldest first.
  List<Map<String, dynamic>> get entries => List.unmodifiable(_entries);

  /// T151 — appends a raw (possibly malformed) entry directly, bypassing
  /// [recordEvent]'s normal AdEvent-shaped serialization. Every real
  /// caller only ever produces well-formed entries; the one way this log
  /// legitimately ends up with a malformed one is an entry written by an
  /// older/different SDK version outliving an upgrade. Lets a test or demo
  /// reproduce that specific persisted-data shape in-memory (never
  /// persisted to disk by this call) instead of only exercising readers
  /// like [AdDiagnostics.lastWaterfallBySlotFrom] with a hand-built list
  /// that bypasses this log entirely.
  @visibleForTesting
  void debugInjectRawEntry(Map<String, dynamic> entry) => _entries.add(entry);

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

  void recordEvent(AdEvent event, {int? timestampMs, String? consentCountry}) {
    _append({
      'kind': 'ad_event',
      'timestampMs': timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      'eventType': event.runtimeType.toString(),
      'providerTag': event.providerTag,
      'slotType': event.type.name,
      'placement': event.placement.id,
      'consentCountry': consentCountry,
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
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceWindow, _schedulePersist);
  }

  void _schedulePersist() {
    _debounceTimer = null;
    _persistChain = _persistChain.then((_) => _persist()).catchError((e) {
      SafeLogger.w(_tag, 'compliance log persist failed: $e');
    });
  }

  /// T102 — test-only hook: when set, awaited right before the write inside
  /// [_persist], to reproduce the real-device timing gap (genuine async
  /// platform-channel I/O) that the in-memory `SharedPreferences` mock is
  /// too fast to ever exhibit on its own.
  @visibleForTesting
  static Duration? debugPersistDelay;

  Future<void> _persist() async {
    final delay = debugPersistDelay;
    if (delay != null) await Future<void>.delayed(delay);
    await _prefs.setComplianceLogRaw(jsonEncode(_entries));
  }

  /// Forces an immediate write, skipping (and cancelling) any pending
  /// debounce window. Call before anything that could kill the process —
  /// e.g. the host app backgrounding — so a debounced event isn't lost.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _schedulePersist();
    await _persistChain;
  }

  /// T79 — max safe integer a JS `Number` can represent exactly
  /// (`2^53 - 1`). Android/iOS `int` is 64-bit and wouldn't need this, but
  /// a future Web/Wasm target would silently lose precision past this
  /// point — using it as the open-ended upper bound is safe everywhere
  /// (no real `timestampMs` will ever approach it) and costs nothing today.
  static const int _maxSafeIntegerMs = 9007199254740991; // 2^53 - 1

  /// Entries with `timestampMs` inside `[from, to]` (inclusive). Null bounds
  /// are open-ended.
  List<Map<String, dynamic>> inRange({DateTime? from, DateTime? to}) {
    if (from == null && to == null) return entries;
    final fromMs = from?.millisecondsSinceEpoch ?? 0;
    final toMs = to?.millisecondsSinceEpoch ?? _maxSafeIntegerMs;
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
      AdImpressionEvent _ => const {},
      AdSkipEvent e => {'action': e.action, 'reason': e.reason},
      AdRewardEvent e => {'label': e.label, 'amount': e.amount},
      AdRevenueEvent e => {
          'valueMicros': e.valueMicros,
          'currencyCode': e.currencyCode,
          'networkName': e.networkName,
          'precision': e.precision,
          'mediationWaterfall': e.mediationWaterfall,
        },
      AdAnomalyEvent e => {
          'reason': e.reason,
          'violationCount': e.violationCount,
          'pauseDurationMs': e.pauseDurationMs,
        },
      ArbitratorNudgeEvent e => {
          'estimatedEcpmMicros': e.estimatedEcpmMicros,
        },
      AdSelfHealingObserveEvent e => {
          'wouldSwitchToProvider': e.wouldSwitchToProvider,
          'currentScore': e.currentScore,
          'recommendedScore': e.recommendedScore,
        },
    };
