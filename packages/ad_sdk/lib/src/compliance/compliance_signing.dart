import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/safe_logger.dart';
import 'compliance_report.dart';

const String _tag = 'ComplianceSigning';
const String _secureKeySeed = 'ad_sdk_compliance_signing_key_v1';
final Ed25519 _ed25519 = Ed25519();

/// T96 — a [ComplianceReport] plus an on-device Ed25519 signature over its
/// exact exported JSON, proving the file wasn't hand-edited after the SDK
/// produced it.
///
/// **Threat model**: this is tamper-*evidence* for a dispute appeal (the
/// exported bytes match what the SDK generated at [ComplianceReport.
/// generatedAt]), not non-repudiation — the signing key lives on the same
/// device that generates the report, so whoever controls the device also
/// controls the key that would need to re-sign a forged copy. It stops a
/// casual after-the-fact edit of the exported file, not a device owner
/// determined to fabricate evidence from scratch.
class SignedComplianceReport {
  const SignedComplianceReport({
    required this.reportJson,
    required this.publicKeyBase64,
    required this.signatureBase64,
  });

  /// The EXACT compact JSON string that was signed (== the [ComplianceReport]
  /// this was built from, via [ComplianceReport.toJsonString]). Kept
  /// verbatim — not re-derived from a parsed object — so verification never
  /// depends on JSON re-serialization producing byte-identical output.
  final String reportJson;

  /// Base64url Ed25519 public key that verifies [signatureBase64]. Travels
  /// WITH the bundle (untrusted input to the verifier) — see the class doc
  /// for what that does and doesn't prove.
  final String publicKeyBase64;

  /// Base64url Ed25519 signature over `utf8.encode(reportJson)`.
  final String signatureBase64;

  Map<String, dynamic> toJson() => {
        'reportJson': reportJson,
        'publicKeyBase64': publicKeyBase64,
        'signatureBase64': signatureBase64,
      };

  String toJsonString({bool pretty = false}) {
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(toJson());
  }
}

/// Signs [report] with an on-device Ed25519 key pair, minting and persisting
/// one (via `flutter_secure_storage`) on first use if none exists yet. The
/// key is stable across exports on the same install, so re-exporting the
/// same window later still verifies against the same public key.
Future<SignedComplianceReport> signComplianceReport(
  ComplianceReport report, {
  FlutterSecureStorage? secureStorage,
}) async {
  final storage = secureStorage ?? const FlutterSecureStorage();
  final keyPair = await _loadOrCreateKeyPair(storage);
  final reportJson = report.toJsonString();
  final sig = await _ed25519.sign(utf8.encode(reportJson), keyPair: keyPair);
  final pub = await keyPair.extractPublicKey();
  return SignedComplianceReport(
    reportJson: reportJson,
    publicKeyBase64: base64Url.encode(pub.bytes),
    signatureBase64: base64Url.encode(sig.bytes),
  );
}

/// T195 — process-wide lock serializing every [_loadOrCreateKeyPairLocked]
/// call. Without it, two callers racing before any key is persisted (e.g.
/// [signComplianceReport] and [signJsonPayload] both firing on first use)
/// both read `null`, both mint their OWN independent Ed25519 key pair, and
/// whichever write wins silently strands the other caller's
/// already-returned signature under a key that will never again match
/// what's persisted — breaking the "same install, same public key across
/// every export" guarantee this file exists to provide. (Each signature
/// stays internally valid on its own — the public key travels WITH the
/// bundle — but cross-export key stability is exactly what this class
/// promises and the race silently defeats.)
///
/// A caller that arrives WHILE another is minting shares that SAME
/// in-flight result (awaits the same [Completer]'s future) instead of
/// racing it. A caller that arrives strictly AFTER the lock has released
/// re-enters [_loadOrCreateKeyPairLocked] fresh, which re-reads storage
/// first — by then the winning write has landed, so it finds the
/// now-persisted key instead of minting a second one. No separate
/// "double-check inside the lock" step is needed on top of that: the
/// existing read-storage-first order already gives every non-concurrent
/// caller the up-to-date value.
Completer<SimpleKeyPair>? _pendingKeyPairLoad;

Future<SimpleKeyPair> _loadOrCreateKeyPair(FlutterSecureStorage storage) {
  final pending = _pendingKeyPairLoad;
  if (pending != null) return pending.future;
  final completer = Completer<SimpleKeyPair>();
  _pendingKeyPairLoad = completer;
  unawaited(() async {
    try {
      completer.complete(await _loadOrCreateKeyPairLocked(storage));
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _pendingKeyPairLoad = null;
    }
  }());
  return completer.future;
}

Future<SimpleKeyPair> _loadOrCreateKeyPairLocked(
    FlutterSecureStorage storage) async {
  try {
    final existing = await storage.read(key: _secureKeySeed);
    if (existing != null) {
      final seed = base64Url.decode(base64Url.normalize(existing));
      // Round-23 audit — `await` is load-bearing, not style: without it the
      // future escapes this try block, so a corrupt/undecodable stored seed
      // surfaced as an unhandled exception to the caller instead of falling
      // through to "mint a new one" below. (pana also charges 20 points for
      // returning a future un-awaited inside a try.)
      return await _ed25519.newKeyPairFromSeed(seed);
    }
  } catch (e) {
    SafeLogger.w(
        _tag, 'could not read stored signing key, minting a new one: $e');
  }
  final fresh = await _ed25519.newKeyPair();
  try {
    final seed = await fresh.extractPrivateKeyBytes();
    await storage.write(key: _secureKeySeed, value: base64Url.encode(seed));
  } catch (e) {
    SafeLogger.w(
        _tag, 'could not persist signing key (will re-mint next export): $e');
  }
  return fresh;
}

/// Verifies a bundle produced by [SignedComplianceReport.toJson] /
/// [SignedComplianceReport.toJsonString]. Returns `true` only if
/// `signatureBase64` verifies against `publicKeyBase64` over
/// `utf8.encode(reportJson)` exactly as stored — never throws, any malformed
/// input is simply not valid.
Future<bool> verifySignedComplianceReportJson(String bundleJson) async {
  try {
    final decoded = jsonDecode(bundleJson) as Map<String, dynamic>;
    final reportJson = decoded['reportJson'] as String;
    final pubBytes = base64Url
        .decode(base64Url.normalize(decoded['publicKeyBase64'] as String));
    final sigBytes = base64Url
        .decode(base64Url.normalize(decoded['signatureBase64'] as String));
    if (pubBytes.length != 32) return false;
    return await _ed25519.verify(
      utf8.encode(reportJson),
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}

/// T125 — a signed arbitrary JSON payload, for exports that aren't a
/// [ComplianceReport] (e.g. `IncidentBundle`). Same shape and threat model
/// as [SignedComplianceReport], generalized to any payload string; the two
/// are kept as separate types (rather than reusing one generic class) so
/// [SignedComplianceReport]'s on-disk `reportJson` key — already consumed by
/// `tool/verify_compliance_report.dart` and any host that parsed a prior
/// export — never changes shape.
class SignedPayload {
  const SignedPayload({
    required this.payloadJson,
    required this.publicKeyBase64,
    required this.signatureBase64,
  });

  final String payloadJson;
  final String publicKeyBase64;
  final String signatureBase64;

  Map<String, dynamic> toJson() => {
        'payloadJson': payloadJson,
        'publicKeyBase64': publicKeyBase64,
        'signatureBase64': signatureBase64,
      };

  String toJsonString({bool pretty = false}) {
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(toJson());
  }
}

/// Signs [payloadJson] with the SAME on-device Ed25519 key as
/// [signComplianceReport] — same [_secureKeySeed], so an incident bundle and
/// a compliance report exported from the same install verify against the
/// same public key.
Future<SignedPayload> signJsonPayload(
  String payloadJson, {
  FlutterSecureStorage? secureStorage,
}) async {
  final storage = secureStorage ?? const FlutterSecureStorage();
  final keyPair = await _loadOrCreateKeyPair(storage);
  final sig = await _ed25519.sign(utf8.encode(payloadJson), keyPair: keyPair);
  final pub = await keyPair.extractPublicKey();
  return SignedPayload(
    payloadJson: payloadJson,
    publicKeyBase64: base64Url.encode(pub.bytes),
    signatureBase64: base64Url.encode(sig.bytes),
  );
}

/// Verifies a bundle produced by [SignedPayload.toJson] /
/// [SignedPayload.toJsonString]. Same semantics as
/// [verifySignedComplianceReportJson] — never throws, malformed input is
/// simply not valid.
Future<bool> verifySignedJsonPayload(String bundleJson) async {
  try {
    final decoded = jsonDecode(bundleJson) as Map<String, dynamic>;
    final payloadJson = decoded['payloadJson'] as String;
    final pubBytes = base64Url
        .decode(base64Url.normalize(decoded['publicKeyBase64'] as String));
    final sigBytes = base64Url
        .decode(base64Url.normalize(decoded['signatureBase64'] as String));
    if (pubBytes.length != 32) return false;
    return await _ed25519.verify(
      utf8.encode(payloadJson),
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}
