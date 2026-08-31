// Replay a signed incident bundle (T125 —
// AdManager().exportSignedIncidentBundle() / IncidentBundle /
// signIncidentBundle in lib/src/compliance/incident_recorder.dart).
//
//   dart run tool/incident_replay.dart <path-to-exported.json>
//
// Verifies the embedded signature (same Ed25519 threat model as
// verify_compliance_report.dart — the public key travels WITH the file, so
// this proves internal consistency, not which device produced it), then
// prints the recorded state-transition timeline in order:
//
//   +0ms adapterInitialized -> isInitialised=true canRequestAds=false ...
//   +842ms consentChanged   -> isInitialised=true canRequestAds=true ...
//
// Exits 1 (and still prints whatever parsed) if the signature doesn't
// verify, so a tampered/corrupted bundle is visibly flagged rather than
// silently trusted. Entirely local — no network call, nothing uploaded.
// Self-contained (no dependency on the SDK's Flutter-only code) so it runs
// under plain `dart run`, same as vip_mint.dart / verify_compliance_report.dart.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/incident_replay.dart <path>');
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
    stderr.writeln('payloadJson is not a valid incident bundle: $e');
    exit(2);
  }

  final generatedAtMs = bundle['generatedAtMs'] as int;
  final fingerprint = bundle['configFingerprint'] as Map<String, dynamic>;
  final entries = (bundle['entries'] as List).cast<Map<String, dynamic>>();

  // ignore: avoid_print
  print('generated: ${DateTime.fromMillisecondsSinceEpoch(generatedAtMs).toIso8601String()}');
  // ignore: avoid_print
  print('config: ${const JsonEncoder.withIndent('  ').convert(fingerprint)}');
  // ignore: avoid_print
  print('${entries.length} entries:');
  for (final e in entries) {
    final label = e['label'] as String;
    final deltaMs = e['deltaMs'] as int;
    final snapshot = {
      'isInitialised': e['isInitialised'],
      'canRequestAds': e['canRequestAds'],
      'isOffline': e['isOffline'],
      'isVipActive': e['isVipActive'],
      'fullscreenBusy': e['fullscreenBusy'],
    };
    // ignore: avoid_print
    print('  +${deltaMs}ms $label -> $snapshot');
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
