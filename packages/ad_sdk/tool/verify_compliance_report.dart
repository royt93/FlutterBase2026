// Verify a signed compliance-report export (T96 —
// AdManager.exportSignedComplianceReport / SignedComplianceReport.toJson).
//
//   dart run tool/verify_compliance_report.dart <path-to-exported.json>
//
// Prints VALID + exits 0 if the embedded signature verifies against the
// embedded reportJson under the embedded publicKeyBase64. Prints INVALID +
// exits 1 otherwise.
//
// This only proves INTERNAL consistency — the file wasn't edited after the
// SDK produced it. The public key travels WITH the file (untrusted input),
// so this alone cannot prove WHICH device/app produced it; combine with an
// out-of-band record of the app's known public key if that matters for your
// dispute process. Self-contained (no dependency on the SDK's Flutter-only
// signing code) so it runs under plain `dart run`, same as vip_mint.dart.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/verify_compliance_report.dart <path>');
    exit(2);
  }

  final String raw;
  try {
    raw = await File(args[0]).readAsString();
  } catch (e) {
    stderr.writeln('could not read ${args[0]}: $e');
    exit(2);
  }

  final ok = await _verify(raw);
  // ignore: avoid_print
  print(ok ? 'VALID' : 'INVALID');
  exit(ok ? 0 : 1);
}

Future<bool> _verify(String bundleJson) async {
  try {
    final decoded = jsonDecode(bundleJson) as Map<String, dynamic>;
    final reportJson = decoded['reportJson'] as String;
    final pubBytes = base64Url
        .decode(base64Url.normalize(decoded['publicKeyBase64'] as String));
    final sigBytes = base64Url
        .decode(base64Url.normalize(decoded['signatureBase64'] as String));
    if (pubBytes.length != 32) return false;
    final ed25519 = Ed25519();
    return await ed25519.verify(
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
