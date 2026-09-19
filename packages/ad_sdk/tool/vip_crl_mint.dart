// Mint a signed VIP-key revocation list (CRL, T95). Same private key as
// tool/vip_mint.dart (from tool/vip_keygen.dart) — no new key material.
//
//   dart tool/vip_crl_mint.dart --priv-file .vip-private-key --kids kid1,kid2,kid3
//
// Use bare `dart tool/vip_crl_mint.dart`, NOT `dart run tool/vip_crl_mint.dart`
// — see tool/vip_mint.dart's header for why (`dart run`'s build-hooks stdout
// noise corrupts a captured CRL string on Dart 3.10+ toolchains).
//
// Mints CRL1.<b64url(payload)>.<b64url(signature)>
// payload = UTF-8 of "<issuedAtEpochSeconds>|<comma-separated kids>"
//
// SECURITY: the bytes actually signed are "CRL1|" + payload, NOT payload
// alone (domain separation — kept in sync with signed_vip_key.dart's private
// `_crlSignedMessage`). Without this, a CRL's <issuedAt>|<kids> shape splits
// into exactly 2 pipe-delimited fields, identical to an AVP1 VIP key's
// <seconds>|<kid> shape — a CRL is meant to be broadcast publicly, so
// without the prefix baked into the signed message, anyone who observes one
// could relabel it "AVP1" and redeem it as a VIP key valid for however many
// "seconds" the CRL's issuedAt epoch happens to equal (tens of years).
//
// Host apps verify+apply this via
// VipManager.refreshRevocationList(publicKeyBase64: ..., revocationProvider: ...)
// — see lib/src/vip/vip_revocation_provider.dart for the fetch-side contract.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  final opts = _parse(args);
  final privB64 = await _readPrivateKey(opts);

  // No '|' in any kid — it's the payload separator, and a stray one would
  // shift field boundaries when signed_vip_key.dart's verifySignedCrl parses
  // the payload back (mirrors vip_mint.dart's identical sanitization of
  // --kid).
  //
  // Upper-cased to match vip_mint.dart: revocation matching goes through
  // `VipManager.normaliseKey('SIGNED_<kid>')`, which upper-cases, so a CRL
  // listing a lower-case kid still has to hit the same entry key. See
  // vip_mint.dart's --kid comment for the collision this avoids.
  final kids = (opts['kids'] ?? '')
      .split(',')
      .map((k) => k.trim().replaceAll('|', '_').toUpperCase())
      .where((k) => k.isNotEmpty)
      .join(',');

  final List<int> seed;
  try {
    seed = base64Url.decode(base64Url.normalize(privB64));
  } catch (_) {
    _fail('--priv is not valid base64url');
  }

  final algo = Ed25519();
  final kp = await algo.newKeyPairFromSeed(seed);
  final issuedAt = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final payload = utf8.encode('$issuedAt|$kids');
  final signedMessage = utf8.encode('CRL1|') + payload;
  final sig = await algo.sign(signedMessage, keyPair: kp);
  final code =
      'CRL1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';

  // ignore: avoid_print
  print(code);
}

Map<String, String> _parse(List<String> args) {
  final m = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final key = a.substring(2);
      final val = (i + 1 < args.length && !args[i + 1].startsWith('--'))
          ? args[++i]
          : 'true';
      m[key] = val;
    }
  }
  return m;
}

Future<String> _readPrivateKey(Map<String, String> opts) async {
  if (opts.containsKey('priv')) {
    _fail(
        '--priv is disabled because argv is observable; use --priv-file or --priv-stdin');
  }
  final path = opts['priv-file'];
  if (path != null) {
    try {
      return (await File(path).readAsString()).trim();
    } catch (_) {
      _fail('could not read --priv-file');
    }
  }
  if (opts.containsKey('priv-stdin')) {
    return (await stdin.transform(utf8.decoder).join()).trim();
  }
  _fail('provide --priv-file <0600 file> or --priv-stdin');
}

Never _fail(String msg) {
  // ignore: avoid_print
  print('ERROR: $msg');
  throw ArgumentError(msg);
}
