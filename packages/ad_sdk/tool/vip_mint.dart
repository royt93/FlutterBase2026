// Mint a signed offline VIP key (T18). Requires the Ed25519 PRIVATE key from
// tool/vip_keygen.dart.
//
//   dart run tool/vip_mint.dart --priv <b64privkey> --days 30 [--kid abc123]
//   dart run tool/vip_mint.dart --priv <b64privkey> --seconds 3600 --kid demo1
//
// Emits a key of the form:  AVP1.<b64url(payload)>.<b64url(signature)>
// where payload = UTF-8 of "<seconds>|<kid>". The user redeems it via
// VipManager.redeemSignedKey(code, publicKeyBase64: <matching public key>).
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  final opts = _parse(args);
  final privB64 = opts['priv'];
  if (privB64 == null) {
    _fail('missing --priv <base64 private key> (from vip_keygen.dart)');
  }

  int? seconds = int.tryParse(opts['seconds'] ?? '');
  final days = int.tryParse(opts['days'] ?? '');
  if (seconds == null && days != null) seconds = days * 24 * 60 * 60;
  if (seconds == null || seconds <= 0) {
    _fail('provide --days N or --seconds N (positive)');
  }

  // kid: caller-supplied or derived from time — must be unique per issued key
  // so per-device one-time-use tracking works. No '|' allowed.
  final kid = (opts['kid'] ?? 'k${DateTime.now().microsecondsSinceEpoch}')
      .replaceAll('|', '_');

  final List<int> seed;
  try {
    seed = base64Url.decode(base64Url.normalize(privB64));
  } catch (_) {
    _fail('--priv is not valid base64url');
  }

  final algo = Ed25519();
  final kp = await algo.newKeyPairFromSeed(seed);
  final payload = utf8.encode('$seconds|$kid');
  final sig = await algo.sign(payload, keyPair: kp);
  final code =
      'AVP1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';

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
