import 'dart:convert';

import 'package:flutter/foundation.dart' show kReleaseMode, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../compliance/compliance_signing.dart';
import '../config/ad_config.dart';
import '../utils/ad_preferences.dart';

/// Single session performance record used by [CohortOptimizer].
class SessionCohortRecord {
  const SessionCohortRecord({
    required this.provider,
    required this.impressions,
    required this.revenueMicros,
    required this.timestampMs,
  });

  final AdProvider provider;
  final int impressions;
  final int revenueMicros;
  final int timestampMs;

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'impressions': impressions,
    'revenueMicros': revenueMicros,
    'timestampMs': timestampMs,
  };

  static SessionCohortRecord fromJson(Map<String, dynamic> json) {
    final impressions = json['impressions'];
    final revenueMicros = json['revenueMicros'];
    final timestampMs = json['timestampMs'];
    if (impressions is! int || revenueMicros is! int || timestampMs is! int) {
      throw const FormatException(
        'Missing or invalid numeric fields in record',
      );
    }
    return SessionCohortRecord(
      provider: json['provider'] == AdProvider.appLovin.name
          ? AdProvider.appLovin
          : AdProvider.admob,
      impressions: impressions,
      revenueMicros: revenueMicros,
      timestampMs: timestampMs,
    );
  }
}

/// Offline, privacy-safe local cohort optimizer.
///
/// Records session-level provider performance signed with on-device Ed25519,
/// and recommends an [AdProvider] for the next initialization.
///
/// Note: This is strictly on-device historical optimization for THIS install,
/// not cross-install server-side optimization.
///
/// Session metrics passed to [recordSession] must be non-negative. Zero is
/// valid for either metric.
class CohortOptimizer {
  CohortOptimizer(
    this._prefs, {
    this.storage = const FlutterSecureStorage(),
    this.minSessionsPerProvider = 3,
  });

  final AdPreferences _prefs;
  final FlutterSecureStorage storage;
  final int minSessionsPerProvider;

  static Future<void> _writeChain = Future<void>.value();
  @visibleForTesting
  static int Function()? debugNowMs;
  @visibleForTesting
  static bool debugSimulateReleaseMode = false;

  /// Records a completed session's metrics, signs the state and saves locally.
  /// Writes are serialized within this Dart isolate.
  Future<void> recordSession({
    required AdProvider provider,
    required int impressions,
    required int revenueMicros,
  }) async {
    if (impressions < 0) {
      throw ArgumentError.value(
        impressions,
        'impressions',
        'must be non-negative',
      );
    }
    if (revenueMicros < 0) {
      throw ArgumentError.value(
        revenueMicros,
        'revenueMicros',
        'must be non-negative',
      );
    }
    final result = _writeChain.then(
      (_) => _recordSessionNow(
        provider: provider,
        impressions: impressions,
        revenueMicros: revenueMicros,
      ),
    );
    _writeChain = result.catchError((Object _) {});
    await result;
  }

  static int _nowMs() => (!kReleaseMode && !debugSimulateReleaseMode)
      ? (debugNowMs?.call() ?? DateTime.now().millisecondsSinceEpoch)
      : DateTime.now().millisecondsSinceEpoch;

  Future<void> _recordSessionNow({
    required AdProvider provider,
    required int impressions,
    required int revenueMicros,
  }) async {
    final now = _nowMs();
    final cutoff = now - const Duration(days: 90).inMilliseconds;
    final state = await _loadVerifiedState();
    if (state.isUnparseable) {
      // Valid signature but unknown schema version (e.g. written by a newer SDK version).
      // Preserve existing payload to avoid destroying future-version history.
      return;
    }

    final records = List<SessionCohortRecord>.of(state.records);
    final anchor = state.trustedClockMs ?? _latestTimestamp(records) ?? now;
    final isRollback = now < anchor - const Duration(days: 7).inMilliseconds;
    final nextAnchor = now > anchor ? now : anchor;

    if (!isRollback) {
      records.removeWhere(
        (record) => record.timestampMs < cutoff || record.timestampMs > now,
      );
    }
    records.add(
      SessionCohortRecord(
        provider: provider,
        impressions: impressions,
        revenueMicros: revenueMicros,
        timestampMs: now,
      ),
    );
    if (records.length > 100) {
      records.removeRange(0, records.length - 100);
    }

    final signedRecords = await signJsonPayload(
      jsonEncode(records.map((r) => r.toJson()).toList()),
      secureStorage: storage,
    );
    final signedAnchor = await signJsonPayload(
      jsonEncode(nextAnchor),
      secureStorage: storage,
    );
    final previousRecordsRaw = _prefs.getCohortOptimizerRecordsRaw();
    if (!await _prefs.setCohortOptimizerRecordsRaw(
      signedRecords.toJsonString(),
    )) {
      throw StateError('Failed to persist cohort optimizer records');
    }
    try {
      if (!await _prefs.setCohortOptimizerClockAnchorRaw(
        signedAnchor.toJsonString(),
      )) {
        throw StateError('Failed to persist cohort optimizer clock anchor');
      }
    } catch (error) {
      try {
        final restored = await _prefs.restoreCohortOptimizerRecordsRaw(
          previousRecordsRaw,
        );
        if (!restored) {
          throw StateError('records restore returned false');
        }
      } catch (restoreError) {
        throw StateError(
          'Clock anchor write failed ($error) and previous cohort records could not be restored ($restoreError)',
        );
      }
      rethrow;
    }
  }

  /// Loads and verifies stored records against on-device Ed25519 signature.
  /// Discards tampered or corrupted records.
  Future<List<SessionCohortRecord>> loadVerifiedRecords() async =>
      (await _loadVerifiedState()).records;

  Future<_CohortState> _loadVerifiedState() async {
    final raw = _prefs.getCohortOptimizerRecordsRaw();
    if (raw == null || raw.isEmpty) {
      return _CohortState(
        records: const [],
        trustedClockMs: await _loadTrustedClockAnchor(),
      );
    }

    if (!await verifySignedJsonPayload(raw)) {
      return _CohortState(
        records: const [],
        trustedClockMs: await _loadTrustedClockAnchor(),
      );
    }

    try {
      final decodedBundle = jsonDecode(raw) as Map<String, dynamic>;
      final payloadJson = decodedBundle['payloadJson'] as String;
      final payload = jsonDecode(payloadJson);
      if (payload is List) {
        final records = _decodeRecords(payload);
        final anchor = await _loadTrustedClockAnchor();
        final latest = _latestTimestamp(records);
        return _CohortState(
          records: records,
          trustedClockMs: anchor == null || (latest != null && latest > anchor)
              ? latest
              : anchor,
        );
      }
      if (payload is Map<String, dynamic> &&
          payload['schemaVersion'] == 1 &&
          payload['trustedClockMs'] is int &&
          payload['records'] is List) {
        return _CohortState(
          records: _decodeRecords(payload['records'] as List<dynamic>),
          trustedClockMs: payload['trustedClockMs'] as int,
        );
      }
      // Verified payload is not a recognizable schema.
      return const _CohortState(
        records: [],
        trustedClockMs: null,
        isUnparseable: true,
      );
    } catch (_) {}
    return const _CohortState(
      records: [],
      trustedClockMs: null,
      isUnparseable: true,
    );
  }

  Future<int?> _loadTrustedClockAnchor() async {
    final raw = _prefs.getCohortOptimizerClockAnchorRaw();
    if (raw == null || raw.isEmpty || !await verifySignedJsonPayload(raw)) {
      return null;
    }
    try {
      final bundle = jsonDecode(raw) as Map<String, dynamic>;
      final anchor = jsonDecode(bundle['payloadJson'] as String);
      return anchor is int ? anchor : null;
    } catch (_) {
      return null;
    }
  }

  List<SessionCohortRecord> _decodeRecords(List<dynamic> list) {
    final records = <SessionCohortRecord>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final provider = item['provider'];
      if (provider != AdProvider.admob.name &&
          provider != AdProvider.appLovin.name) {
        continue;
      }
      try {
        final record = SessionCohortRecord.fromJson(item);
        if (record.impressions < 0 || record.revenueMicros < 0) continue;
        records.add(record);
      } on Object {
        continue;
      }
    }
    return records;
  }

  int? _latestTimestamp(List<SessionCohortRecord> records) {
    int? latest;
    for (final record in records) {
      if (latest == null || record.timestampMs > latest) {
        latest = record.timestampMs;
      }
    }
    return latest;
  }

  /// Returns recommended [AdProvider] for next init, or null if insufficient data.
  Future<AdProvider?> recommendedProviderForNextInit() async {
    final now = _nowMs();
    final cutoff = now - const Duration(days: 90).inMilliseconds;
    final records = (await loadVerifiedRecords())
        .where(
          (record) => record.timestampMs >= cutoff && record.timestampMs <= now,
        )
        .toList();

    final admobRecords = records
        .where((r) => r.provider == AdProvider.admob)
        .toList();
    final appLovinRecords = records
        .where((r) => r.provider == AdProvider.appLovin)
        .toList();

    if (admobRecords.length < minSessionsPerProvider ||
        appLovinRecords.length < minSessionsPerProvider) {
      return null;
    }

    final admobEcpm = _calculateAverageEcpm(admobRecords);
    final appLovinEcpm = _calculateAverageEcpm(appLovinRecords);

    if (admobEcpm > appLovinEcpm) {
      return AdProvider.admob;
    } else if (appLovinEcpm > admobEcpm) {
      return AdProvider.appLovin;
    }
    return null;
  }

  double _calculateAverageEcpm(List<SessionCohortRecord> records) {
    var totalImpressions = 0.0;
    var totalRevenueMicros = 0.0;

    for (final record in records) {
      totalImpressions += record.impressions.toDouble();
      totalRevenueMicros += record.revenueMicros.toDouble();
    }

    if (totalImpressions <= 0) return 0.0;
    return (totalRevenueMicros / totalImpressions) * 1000.0;
  }
}

class _CohortState {
  const _CohortState({
    required this.records,
    required this.trustedClockMs,
    this.isUnparseable = false,
  });

  final List<SessionCohortRecord> records;
  final int? trustedClockMs;
  final bool isUnparseable;
}
