// Mint a signed VIP-key revocation list (CRL, T95). Same private key as
// tool/vip_mint.dart (from tool/vip_keygen.dart) — no new key material.
//
//   dart run tool/vip_crl_mint.dart --priv <b64privkey> --kids kid1,kid2,kid3
//
// Mints CRL1.<b64url(payload)>.<b64url(signature)>
// payload = UTF-8 of "<issuedAtEpochSeconds>|<comma-separated kids>"
//
// Host apps verify+apply this via
// VipManager.refreshRevocationList(publicKeyBase64: ..., revocationProvider: ...)
// — see lib/src/vip/vip_revocation_provider.dart for the fetch-side contract.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  final opts = _parse(args);
  final privB64 = opts['priv'];
  if (privB64 == null) {
    _fail('missing --priv <base64 private key> (from vip_keygen.dart)');
  }

  final kids = (opts['kids'] ?? '')
      .split(',')
      .map((k) => k.trim())
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
  final sig = await algo.sign(payload, keyPair: kp);
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

Never _fail(String msg) {
  // ignore: avoid_print
  print('ERROR: $msg');
  throw ArgumentError(msg);
}
