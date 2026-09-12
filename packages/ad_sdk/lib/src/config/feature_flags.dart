import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Signed, expiring kill-switch payload for experimental SDK features.
class SignedFeatureFlags {
  const SignedFeatureFlags({
    required this.revision,
    required this.expiresAt,
    required this.flags,
    required this.signatureBase64,
  });

  final int revision;
  final DateTime expiresAt;
  final Map<String, bool> flags;
  final String signatureBase64;

  Map<String, dynamic> get payload => {
        'schemaVersion': 1,
        'revision': revision,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'flags': flags,
      };

  String canonicalPayload() => jsonEncode(payload);

  factory SignedFeatureFlags.fromJson(Map<String, dynamic> json) =>
      SignedFeatureFlags(
        revision: json['revision'] is int ? json['revision'] as int : -1,
        expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        flags: (json['flags'] is Map)
            ? (json['flags'] as Map).map<String, bool>(
                (key, value) => MapEntry(key.toString(), value == true))
            : const {},
        signatureBase64: json['signatureBase64'] as String? ?? '',
      );

  /// Verifies signature, revision, expiry, and fail-safe flag types.
  Future<bool> verify({
    required String publicKeyBase64,
    int? previousRevision,
    DateTime? now,
  }) async {
    if (revision < 0 ||
        (previousRevision != null && revision < previousRevision) ||
        !expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      return false;
    }
    try {
      final key = SimplePublicKey(
        base64Url.decode(base64Url.normalize(publicKeyBase64)),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        base64Url.decode(base64Url.normalize(signatureBase64)),
        publicKey: key,
      );
      return await Ed25519()
          .verify(utf8.encode(canonicalPayload()), signature: signature);
    } catch (_) {
      return false;
    }
  }
}
