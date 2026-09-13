import 'dart:convert';

/// Why the SDK had to use its conservative consent fallback.
enum ConsentFallbackReason { timeout, platformError, offline, staleRevision }

/// The policy revision every fresh [ConsentFallbackState] this SDK records
/// is stamped with.
///
/// Audit fix (post-T210) — this used to be the literal string `'ump-v1'`
/// duplicated inline at the one call site in `AdManager._requestUmpConsent`
/// and independently in tests, with nothing tying them together and no
/// declared meaning for what "the policy revision" actually versions. Bump
/// this constant when the UMP consent form / underlying privacy policy this
/// SDK requests consent under changes meaningfully — [ConsentManager]
/// compares a persisted fallback's `policyRevision` against this value on
/// load and reclassifies a mismatch as [ConsentFallbackReason.staleRevision]
/// so a host reading [ConsentManager.fallback] can tell a fallback recorded
/// under a policy epoch that no longer applies from a fresh one.
const String kUmpPolicyRevision = 'ump-v1';

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
