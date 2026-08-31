// Replay a signed bypass audit trail (T128 —
// AdManager().exportSignedBypassAuditTrail() / BypassAuditTrail /
// signBypassAuditTrail in lib/src/compliance/bypass_audit_trail.dart).
//
//   dart run tool/bypass_audit_replay.dart <path-to-exported.json>
//
// Verifies the embedded signature (same Ed25519 threat model as
// verify_compliance_report.dart / incident_replay.dart — the public key
// travels WITH the file, so this proves internal consistency, not which
// device produced it), then prints every recorded bypassSafety/
// bypassVipGuard call in order:
//
//   +0ms bypassSafety     [appOpen]  site=splash_app_open
//   +842ms bypassVipGuard [rewarded] site=vip_extend_screen
//
// Exits 1 (and still prints whatever parsed) if the signature doesn't
// verify, so a tampered/corrupted bundle is visibly flagged rather than
// silently trusted. Entirely local — no network call, nothing uploaded.
// Self-contained (no dependency on the SDK's Flutter-only code) so it runs
// under plain `dart run`, same as vip_mint.dart / incident_replay.dart.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/bypass_audit_replay.dart <path>');
    exit(2);
  }

  final String raw;
  try {
    raw = await File(args[0]).readAsString();
  } catch (e) {
    stderr.writeln('could not read ${args[0]}: $e');
    exit(2);
  }

  Map<String, dynamic> bundleEnvelope;
  String payloadJson;
  try {
    bundleEnvelope = jsonDecode(raw) as Map<String, dynamic>;
    payloadJson = bundleEnvelope['payloadJson'] as String;
  } catch (e) {
    stderr.writeln('not a valid signed bundle: $e');
    exit(2);
  }

  final signatureValid = await _verify(bundleEnvelope, payloadJson);
  // ignore: avoid_print
  print(signatureValid ? 'signature: VALID' : 'signature: INVALID');

  final Map<String, dynamic> bundle;
  try {
    bundle = jsonDecode(payloadJson) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('payloadJson is not a valid bypass audit trail: $e');
    exit(2);
  }

  final generatedAtMs = bundle['generatedAtMs'] as int;
  final entries = (bundle['entries'] as List).cast<Map<String, dynamic>>();

  // ignore: avoid_print
  print('generated: '
      '${DateTime.fromMillisecondsSinceEpoch(generatedAtMs).toIso8601String()}');
  // ignore: avoid_print
  print('${entries.length} entries:');
  int? firstMs;
  for (final e in entries) {
    final ts = e['timestampMs'] as int;
    firstMs ??= ts;
    final kind = (e['kind'] as String).padRight(16);
    final type = e['type'] as String;
    final callSiteTag = e['callSiteTag'] as String;
    // ignore: avoid_print
    print('  +${ts - firstMs}ms $kind [$type] site=$callSiteTag');
  }

  exit(signatureValid ? 0 : 1);
}

Future<bool> _verify(
    Map<String, dynamic> envelope, String payloadJson) async {
  try {
    final pubBytes = base64Url
        .decode(base64Url.normalize(envelope['publicKeyBase64'] as String));
    final sigBytes = base64Url
        .decode(base64Url.normalize(envelope['signatureBase64'] as String));
    if (pubBytes.length != 32) return false;
    final ed25519 = Ed25519();
    return await ed25519.verify(
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
