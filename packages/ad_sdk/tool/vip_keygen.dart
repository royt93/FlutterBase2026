// Generate an Ed25519 key pair for signing offline VIP keys (T18).
//
//   dart tool/vip_keygen.dart
//
// Use bare `dart tool/vip_keygen.dart`, NOT `dart run tool/vip_keygen.dart`
// — see tool/vip_mint.dart's header for why (`dart run`'s build-hooks stdout
// noise corrupts captured output on Dart 3.10+ toolchains).
//
// • Embed the PUBLIC key in your app (AdConfig.vipPublicKeyBase64 / host
//   vip_keys.dart). It is safe to ship and commit.
// • Keep the PRIVATE key SECRET — never commit it, never ship it. Store it in a
//   password manager / CI secret. You mint keys with it via tool/vip_mint.dart.
//
// Because only the public key ships, a decompiler cannot forge new valid keys.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main([List<String> args = const []]) async {
  final algo = Ed25519();
  final kp = await algo.newKeyPair();
  final priv = await kp.extractPrivateKeyBytes(); // 32-byte seed
  final pub = (await kp.extractPublicKey()).bytes;

  final opts = _parse(args);
  final privatePath = opts['private-out'] ?? '.vip-private-key';
  final privateFile = File(privatePath);
  if (await privateFile.exists() && !opts.containsKey('force')) {
    _fail('refusing to overwrite existing private-key file; use --force');
  }
  await privateFile.writeAsString(base64Url.encode(priv), flush: true);
  if (!Platform.isWindows) {
    final chmod = await Process.run('chmod', ['600', privateFile.path]);
    if (chmod.exitCode != 0) {
      _fail('could not set private-key file permissions to 0600');
    }
  }
  // ignore: avoid_print
  print('Ed25519 VIP signing key pair');
  // ignore: avoid_print
  print('PUBLIC  (embed in app, safe to commit): ${base64Url.encode(pub)}');
  // ignore: avoid_print
  print('PRIVATE stored in 0600 file: $privatePath (never commit)');
}

Map<String, String> _parse(List<String> args) {
  final m = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    m[key] = (i + 1 < args.length && !args[i + 1].startsWith('--'))
        ? args[++i]
        : 'true';
  }
  return m;
}

Never _fail(String msg) {
  // ignore: avoid_print
  print('ERROR: $msg');
  throw ArgumentError(msg);
}
