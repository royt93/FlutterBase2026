// Verify a signed .adproof flight-recorder evidence bundle.
//
//   dart run tool/verify_adproof.dart <path-to-exported.adproof>
//
// Prints VALID + exits 0 if the embedded signature verifies against the
// embedded payloadJson under the embedded publicKeyBase64 AND the hash chain
// across all entries is intact. Prints INVALID + exits 1 otherwise.
// Missing file or usage errors print to stderr and exit 2.
//
// Self-contained (no dependency on the SDK's Flutter-only code) so it runs
// under plain `dart run`.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/verify_adproof.dart <path>');
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
    final payloadJson = decoded['payloadJson'] as String?;
    if (payloadJson == null) return false;
    final pubBytes = base64Url
        .decode(base64Url.normalize(decoded['publicKeyBase64'] as String));
    final sigBytes = base64Url
        .decode(base64Url.normalize(decoded['signatureBase64'] as String));
    if (pubBytes.length != 32) return false;

    final ed25519 = Ed25519();
    final sigOk = await ed25519.verify(
      utf8.encode(payloadJson),
      signature: Signature(
        sigBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!sigOk) return false;

    final bundle = jsonDecode(payloadJson) as Map<String, dynamic>;
    final entriesRaw = bundle['entries'] as List?;
    if (entriesRaw == null) return false;

    final sha256 = Sha256();
    String expectedPrevious = entriesRaw.isEmpty
        ? ''
        : entriesRaw.first['previousHash'] as String? ?? '';

    for (final eRaw in entriesRaw) {
      if (eRaw is! Map<String, dynamic>) return false;
      final e = eRaw;
      final previousHash = e['previousHash'] as String? ?? '';
      if (previousHash != expectedPrevious) return false;

      final canonical = jsonEncode([
        previousHash,
        e['timestampMs'] as int,
        e['label'] as String,
        e['slotType'] as String,
        e['placement'] as String,
        e['providerTag'] as String,
        (e['viewabilityFraction'] as num).toDouble(),
        (e['screenX'] as num).toDouble(),
        (e['screenY'] as num).toDouble(),
        (e['widthPx'] as num).toDouble(),
        (e['heightPx'] as num).toDouble(),
        e['tcfConsentString'] as String?,
        e['touchActive'] as bool,
        e['interactionDurationMs'] as int? ?? 0,
      ]);

      final digest = await sha256.hash(utf8.encode(canonical));
      final recomputed =
          digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      final hash = e['hash'] as String?;
      if (hash == null || recomputed != hash) return false;

      expectedPrevious = hash;
    }

    return true;
  } catch (_) {
    return false;
  }
}
