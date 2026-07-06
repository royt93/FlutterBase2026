// Generate an Ed25519 key pair for signing offline VIP keys (T18).
//
//   dart run tool/vip_keygen.dart
//
// • Embed the PUBLIC key in your app (AdConfig.vipPublicKeyBase64 / host
//   vip_keys.dart). It is safe to ship and commit.
// • Keep the PRIVATE key SECRET — never commit it, never ship it. Store it in a
//   password manager / CI secret. You mint keys with it via tool/vip_mint.dart.
//
// Because only the public key ships, a decompiler cannot forge new valid keys.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

Future<void> main() async {
  final algo = Ed25519();
  final kp = await algo.newKeyPair();
  final priv = await kp.extractPrivateKeyBytes(); // 32-byte seed
  final pub = (await kp.extractPublicKey()).bytes;

  // ignore: avoid_print
  print('Ed25519 VIP signing key pair');
  // ignore: avoid_print
  print('PUBLIC  (embed in app, safe to commit): ${base64Url.encode(pub)}');
  // ignore: avoid_print
  print('PRIVATE (KEEP SECRET, never commit):    ${base64Url.encode(priv)}');
}
