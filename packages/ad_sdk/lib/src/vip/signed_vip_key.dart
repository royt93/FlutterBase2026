import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../utils/safe_logger.dart';
import 'vip_entry.dart';

const String _tag = 'SignedVipKey';

/// A decoded, signature-verified VIP key.
class SignedVipKey {
  const SignedVipKey({
    required this.duration,
    required this.keyId,
    this.expiresAt,
    this.bundleId,
  });

  /// When the KEY stops being redeemable (AVP2 only; `null` for AVP1, which
  /// cannot express it). Distinct from the VIP window the key grants — that is
  /// [duration], measured from the moment of redemption.
  final DateTime? expiresAt;

  /// App this key is restricted to (AVP2 only). `null` or empty = any app.
  final String? bundleId;

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

/// Wire formats, both accepted:
///
///   `AVP1.<b64url(payload)>.<b64url(signature)>`  payload = `<seconds>|<keyId>`
///   `AVP2.<b64url(payload)>.<b64url(signature)>`  payload =
///       `<seconds>|<keyId>|<expiresAtEpochSeconds>|<bundleId>`
///
/// AVP2 adds two bindings that AVP1 could not express, both INSIDE the signed
/// payload so neither can be edited without invalidating the signature:
///
///   * `expiresAtEpochSeconds` — the key stops being redeemable at that
///     instant. AVP1 keys never expire, so one leaked key was valid forever on
///     every device that had not already used it.
///   * `bundleId` — the key only works in that app. Empty string = any app.
///
/// AVP1 stays accepted so keys already handed out keep working.
const String _prefixV1 = 'AVP1';
const String _prefixV2 = 'AVP2';

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

  /// Bundle id of the running app, used to enforce an AVP2 key's app binding.
  /// Empty/null skips the check — callers that cannot determine it still
  /// verify the signature and the expiry.
  String? currentBundleId,

  /// Injectable clock so expiry can be tested without waiting.
  DateTime? now,
}) async {
  final parts = code.trim().split('.');
  final version = parts.isEmpty ? '' : parts[0];
  if (parts.length != 3 || (version != _prefixV1 && version != _prefixV2)) {
    throw const VipKeyException(
        'bad format (expected AVP1|AVP2.<payload>.<sig>)');
  }

  final Uint8List payload;
  final Uint8List sig;
  try {
    payload = _b64urlDecode(parts[1]);
    sig = _b64urlDecode(parts[2]);
  } catch (_) {
    throw const VipKeyException('bad base64');
  }

  // Comma-separated = key rotation without invalidating codes already handed
  // out: list the new public key first and keep the retired one after it. A
  // code verifies if ANY listed key signed it.
  //
  // Rotation is only half a fix on its own. Whoever knows a retired key's
  // codes can still redeem them for as long as that key stays listed — so
  // rotating away from a LEAKED key means dropping it from this list, not just
  // adding a new one ahead of it.
  final keys = publicKeyBase64
      .split(',')
      .map((k) => k.trim())
      .where((k) => k.isNotEmpty)
      .toList();
  if (keys.isEmpty) throw const VipKeyException('bad public key');

  // One malformed key in the rotation list (a stray comma, a bad copy-paste)
  // must not take every OTHER key down with it — try each key and only give
  // up once none of them verified.
  var ok = false;
  for (var i = 0; i < keys.length; i++) {
    final key = keys[i];
    final List<int> pubBytes;
    try {
      pubBytes = _b64AnyDecode(key);
    } catch (_) {
      SafeLogger.d(_tag, 'rotation key #$i skipped: bad base64');
      continue;
    }
    if (pubBytes.length != 32) {
      SafeLogger.d(_tag,
          'rotation key #$i skipped: wrong length (${pubBytes.length}, expected 32)');
      continue;
    }
    ok = await _ed25519.verify(
      payload,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
      ),
    );
    if (ok) break;
  }
  if (!ok) throw const VipKeyException('signature invalid');

  final String text;
  try {
    text = utf8.decode(payload);
  } catch (_) {
    throw const VipKeyException('payload not UTF-8');
  }
  final f = text.split('|');
  final expectedFields = version == _prefixV2 ? 4 : 2;
  if (f.length != expectedFields) {
    throw const VipKeyException('bad payload shape');
  }
  final seconds = int.tryParse(f[0]);
  final kid = f[1];
  if (seconds == null || seconds <= 0 || seconds > _maxSeconds || kid.isEmpty) {
    throw const VipKeyException('bad payload fields');
  }

  if (version == _prefixV1) {
    return SignedVipKey(duration: Duration(seconds: seconds), keyId: kid);
  }

  final expEpoch = int.tryParse(f[2]);
  if (expEpoch == null || expEpoch <= 0) {
    throw const VipKeyException('bad expiry field');
  }
  final expiresAt =
      DateTime.fromMillisecondsSinceEpoch(expEpoch * 1000, isUtc: true);
  final at = (now ?? DateTime.now()).toUtc();
  if (!at.isBefore(expiresAt)) {
    throw VipKeyException('key expired at ${expiresAt.toIso8601String()}');
  }

  // Comma-separated, because one app is not one bundle id. This repo's own
  // host app ships as `com.saigonphantomlabs.base` on iOS and
  // `com.roy.admobwrapper` on Android, so a single-value binding would have
  // rejected every redemption on whichever platform was not minted for — after
  // the keys had already been handed out. Any listed id matches.
  final boundBundle = f[3];
  final allowed = boundBundle
      .split(',')
      .map((b) => b.trim())
      .where((b) => b.isNotEmpty)
      .toList();
  if (allowed.isNotEmpty &&
      currentBundleId != null &&
      currentBundleId.isNotEmpty &&
      !allowed.contains(currentBundleId)) {
    throw VipKeyException(
        'key is bound to ${allowed.join(', ')}, not $currentBundleId');
  }

  return SignedVipKey(
    duration: Duration(seconds: seconds),
    keyId: kid,
    expiresAt: expiresAt,
    bundleId: boundBundle.isEmpty ? null : boundBundle,
  );
}

Uint8List _b64urlDecode(String s) => base64Url.decode(base64Url.normalize(s));

List<int> _b64AnyDecode(String s) {
  try {
    return base64Url.decode(base64Url.normalize(s));
  } catch (_) {
    return base64.decode(base64.normalize(s));
  }
}
