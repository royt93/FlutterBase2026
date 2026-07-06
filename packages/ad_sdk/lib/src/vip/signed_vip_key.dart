import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vip_entry.dart';

/// A decoded, signature-verified VIP key.
class SignedVipKey {
  const SignedVipKey({required this.duration, required this.keyId});

  /// VIP window granted by this key.
  final Duration duration;

  /// Unique id embedded in the key — used for per-device one-time-use tracking
  /// and analytics. NOT a secret.
  final String keyId;
}

/// Thrown when a key is malformed or its signature does not verify.
class VipKeyException implements Exception {
  const VipKeyException(this.message);
  final String message;
  @override
  String toString() => 'VipKeyException: $message';
}

/// Outcome of [redeemSignedKey]-style flows.
enum VipRedeemStatus { success, invalid, alreadyUsed }

class SignedVipRedeemResult {
  const SignedVipRedeemResult.success(VipEntry this.entry)
      : status = VipRedeemStatus.success,
        error = null;
  const SignedVipRedeemResult.invalid(String this.error)
      : status = VipRedeemStatus.invalid,
        entry = null;
  const SignedVipRedeemResult.alreadyUsed()
      : status = VipRedeemStatus.alreadyUsed,
        entry = null,
        error = null;

  final VipRedeemStatus status;
  final VipEntry? entry;
  final String? error;

  bool get ok => status == VipRedeemStatus.success;
}

/// Wire format: `AVP1.<b64url(payload)>.<b64url(signature)>`
/// where `payload` = UTF-8 of `"<seconds>|<keyId>"`.
const String _prefix = 'AVP1';

/// Upper bound so a corrupt/absurd key can't create a 10 000-year entry.
const int _maxSeconds = 100 * 365 * 24 * 60 * 60; // ~100 years

final Ed25519 _ed25519 = Ed25519();

/// Verify an **offline signed** VIP key against [publicKeyBase64] (base64 or
/// base64url of the 32-byte Ed25519 public key).
///
/// Returns the decoded [SignedVipKey], or throws [VipKeyException] when the key
/// is malformed or the signature does not verify.
///
/// Security model: keys are minted **offline** with the Ed25519 *private* key
/// (see `tool/vip_mint.dart`), which never ships. Only the *public* key is
/// embedded in the app, so decompiling the binary reveals nothing that lets an
/// attacker forge a NEW valid key. (A leaked key can still be reused on other
/// devices — true global one-time-use needs a server; per-device reuse is
/// blocked by the redeemed-id store.)
Future<SignedVipKey> verifySignedVipKey(
  String code, {
  required String publicKeyBase64,
}) async {
  final parts = code.trim().split('.');
  if (parts.length != 3 || parts[0] != _prefix) {
    throw const VipKeyException('bad format (expected AVP1.<payload>.<sig>)');
  }

  final Uint8List payload;
  final Uint8List sig;
  try {
    payload = _b64urlDecode(parts[1]);
    sig = _b64urlDecode(parts[2]);
  } catch (_) {
    throw const VipKeyException('bad base64');
  }

  final List<int> pubBytes;
  try {
    pubBytes = _b64AnyDecode(publicKeyBase64);
  } catch (_) {
    throw const VipKeyException('bad public key');
  }
  if (pubBytes.length != 32) {
    throw const VipKeyException('public key must be 32 bytes (Ed25519)');
  }

  final pub = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
  final ok = await _ed25519.verify(
    payload,
    signature: Signature(sig, publicKey: pub),
  );
  if (!ok) throw const VipKeyException('signature invalid');

  final String text;
  try {
    text = utf8.decode(payload);
  } catch (_) {
    throw const VipKeyException('payload not UTF-8');
  }
  final f = text.split('|');
  if (f.length != 2) throw const VipKeyException('bad payload shape');
  final seconds = int.tryParse(f[0]);
  final kid = f[1];
  if (seconds == null || seconds <= 0 || seconds > _maxSeconds || kid.isEmpty) {
    throw const VipKeyException('bad payload fields');
  }
  return SignedVipKey(duration: Duration(seconds: seconds), keyId: kid);
}

Uint8List _b64urlDecode(String s) => base64Url.decode(base64Url.normalize(s));

List<int> _b64AnyDecode(String s) {
  try {
    return base64Url.decode(base64Url.normalize(s));
  } catch (_) {
    return base64.decode(base64.normalize(s));
  }
}
