import 'dart:convert';

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

  static SessionCohortRecord fromJson(Map<String, dynamic> json) =>
      SessionCohortRecord(
        provider: json['provider'] == AdProvider.appLovin.name
            ? AdProvider.appLovin
            : AdProvider.admob,
        impressions: json['impressions'] as int? ?? 0,
        revenueMicros: json['revenueMicros'] as int? ?? 0,
        timestampMs: json['timestampMs'] as int? ?? 0,
      );
}

/// Offline, privacy-safe local cohort optimizer.
///
/// Records session-level provider performance signed with on-device Ed25519,
/// and recommends an [AdProvider] for the next initialization.
///
/// Note: This is strictly on-device historical optimization for THIS install,
/// not cross-install server-side optimization.
class CohortOptimizer {
  CohortOptimizer(
    this._prefs, {
    this.storage = const FlutterSecureStorage(),
    this.minSessionsPerProvider = 3,
  });

  final AdPreferences _prefs;
  final FlutterSecureStorage storage;
  final int minSessionsPerProvider;

  /// Records a completed session's metrics, signs the state and saves locally.
  Future<void> recordSession({
    required AdProvider provider,
    required int impressions,
    required int revenueMicros,
  }) async {
    final records = await loadVerifiedRecords();
    records.add(SessionCohortRecord(
      provider: provider,
      impressions: impressions,
      revenueMicros: revenueMicros,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    ));

    final payloadJson = jsonEncode(records.map((r) => r.toJson()).toList());
    final signed = await signJsonPayload(
      payloadJson,
      secureStorage: storage,
    );
    await _prefs.setCohortOptimizerRecordsRaw(signed.toJsonString());
  }

  /// Loads and verifies stored records against on-device Ed25519 signature.
  /// Discards tampered or corrupted records.
  Future<List<SessionCohortRecord>> loadVerifiedRecords() async {
    final raw = _prefs.getCohortOptimizerRecordsRaw();
    if (raw == null || raw.isEmpty) return <SessionCohortRecord>[];

    final valid = await verifySignedJsonPayload(raw);
    if (!valid) return <SessionCohortRecord>[];

    try {
      final decodedBundle = jsonDecode(raw) as Map<String, dynamic>;
      final payloadJson = decodedBundle['payloadJson'] as String;
      final list = jsonDecode(payloadJson) as List<dynamic>;
      return list
          .map((item) =>
              SessionCohortRecord.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return <SessionCohortRecord>[];
    }
  }

  /// Returns recommended [AdProvider] for next init, or null if insufficient data.
  Future<AdProvider?> recommendedProviderForNextInit() async {
    final records = await loadVerifiedRecords();

    final admobRecords =
        records.where((r) => r.provider == AdProvider.admob).toList();
    final appLovinRecords =
        records.where((r) => r.provider == AdProvider.appLovin).toList();

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
    var totalImpressions = 0;
    var totalRevenueMicros = 0;

    for (final r in records) {
      totalImpressions += r.impressions;
      totalRevenueMicros += r.revenueMicros;
    }

    if (totalImpressions <= 0) return 0.0;
    return (totalRevenueMicros / totalImpressions) * 1000.0;
  }
}
