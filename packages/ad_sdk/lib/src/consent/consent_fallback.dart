import 'dart:convert';

/// Why the SDK had to use its conservative consent fallback.
enum ConsentFallbackReason { timeout, platformError, offline, staleRevision }

/// Versioned provenance for an offline/error consent decision.
class ConsentFallbackState {
  const ConsentFallbackState({
    required this.policyRevision,
    required this.reason,
    required this.recordedAt,
  });

  static const int schemaVersion = 2;
  final String policyRevision;
  final ConsentFallbackReason reason;
  final DateTime recordedAt;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'policyRevision': policyRevision,
        'reason': reason.name,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
        'canRequestAds': false,
        'personalizedAds': false,
      };

  String encode() => jsonEncode(toJson());

  factory ConsentFallbackState.decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      throw const FormatException('missing fallback state');
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('fallback state is not an object');
    }
    final revision = value['policyRevision'] as String? ?? 'legacy';
    final reasonName = value['reason'] as String? ?? 'platformError';
    final reason = ConsentFallbackReason.values.firstWhere(
      (r) => r.name == reasonName,
      orElse: () => ConsentFallbackReason.platformError,
    );
    final recorded = DateTime.tryParse(value['recordedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return ConsentFallbackState(
      policyRevision: revision,
      reason: reason,
      recordedAt: recorded.toUtc(),
    );
  }

  /// Conservative decision: no fallback path may request personalized ads.
  static ConsentFallbackState create({
    required String policyRevision,
    required ConsentFallbackReason reason,
    DateTime? now,
  }) =>
      ConsentFallbackState(
        policyRevision: policyRevision,
        reason: reason,
        recordedAt: (now ?? DateTime.now()).toUtc(),
      );
}
