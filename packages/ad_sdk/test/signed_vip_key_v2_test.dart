// AVP2 signed VIP keys — the expiry and app-binding added in 2.0.0.
//
// AVP1 could express neither, so one leaked key stayed valid forever on every
// device that had not already redeemed it, in any app sharing the public key.
// Both new fields live INSIDE the signed payload, so the point of these tests
// is as much "cannot be edited" as "is enforced".
import 'dart:convert';

import 'package:applovin_admob_sdk/src/vip/signed_vip_key.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

final _ed = Ed25519();

Future<String> _pub(SimpleKeyPair kp) async =>
    base64Url.encode((await kp.extractPublicKey()).bytes);

Future<String> _mint(
  SimpleKeyPair kp, {
  required int seconds,
  required String kid,
  DateTime? expiresAt,
  String bundle = '',
  bool v1 = false,
}) async {
  final payload = v1
      ? utf8.encode('$seconds|$kid')
      : utf8.encode('$seconds|$kid|'
          '${expiresAt!.toUtc().millisecondsSinceEpoch ~/ 1000}|$bundle');
  final sig = await _ed.sign(payload, keyPair: kp);
  return '${v1 ? 'AVP1' : 'AVP2'}.'
      '${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
}

void main() {
  late SimpleKeyPair kp;
  late String pub;
  final now = DateTime.utc(2026, 8, 2, 12);

  setUp(() async {
    kp = await _ed.newKeyPair();
    pub = await _pub(kp);
  });

  group('AVP2 expiry', () {
    test('a key inside its validity window verifies', () async {
      final code = await _mint(kp,
          seconds: 3600,
          kid: 'k1',
          expiresAt: now.add(const Duration(days: 1)));
      final parsed =
          await verifySignedVipKey(code, publicKeyBase64: pub, now: now);
      expect(parsed.duration, const Duration(seconds: 3600));
      expect(parsed.keyId, 'k1');
      expect(parsed.expiresAt, isNotNull);
    });

    test('a key past its expiry is rejected', () async {
      final code = await _mint(kp,
          seconds: 3600,
          kid: 'k2',
          expiresAt: now.subtract(const Duration(seconds: 1)));
      expect(
        () => verifySignedVipKey(code, publicKeyBase64: pub, now: now),
        throwsA(isA<VipKeyException>()
            .having((e) => e.message, 'message', contains('expired'))),
      );
    });

    test('expiry is exclusive — exactly at the instant is already expired',
        () async {
      final code = await _mint(kp, seconds: 3600, kid: 'k3', expiresAt: now);
      expect(
        () => verifySignedVipKey(code, publicKeyBase64: pub, now: now),
        throwsA(isA<VipKeyException>()),
      );
    });

    test('the expiry cannot be edited without breaking the signature',
        () async {
      final code = await _mint(kp,
          seconds: 3600,
          kid: 'k4',
          expiresAt: now.subtract(const Duration(days: 1)));
      // Re-encode the payload with a far-future expiry, keep the old signature.
      final parts = code.split('.');
      final tampered = utf8
          .decode(base64Url.decode(base64Url.normalize(parts[1])))
          .split('|');
      tampered[2] =
          '${now.add(const Duration(days: 3650)).millisecondsSinceEpoch ~/ 1000}';
      final forged = 'AVP2.'
          '${base64Url.encode(utf8.encode(tampered.join('|')))}.${parts[2]}';
      expect(
        () => verifySignedVipKey(forged, publicKeyBase64: pub, now: now),
        throwsA(isA<VipKeyException>()
            .having((e) => e.message, 'message', contains('signature'))),
      );
    });
  });

  group('AVP2 app binding', () {
    test('matching bundle id verifies', () async {
      final code = await _mint(kp,
          seconds: 60,
          kid: 'b1',
          expiresAt: now.add(const Duration(days: 1)),
          bundle: 'com.roy.app');
      final parsed = await verifySignedVipKey(code,
          publicKeyBase64: pub, now: now, currentBundleId: 'com.roy.app');
      expect(parsed.bundleId, 'com.roy.app');
    });

    test('a key bound to another app is rejected', () async {
      final code = await _mint(kp,
          seconds: 60,
          kid: 'b2',
          expiresAt: now.add(const Duration(days: 1)),
          bundle: 'com.someone.else');
      expect(
        () => verifySignedVipKey(code,
            publicKeyBase64: pub, now: now, currentBundleId: 'com.roy.app'),
        throwsA(isA<VipKeyException>()
            .having((e) => e.message, 'message', contains('bound to'))),
      );
    });

    test('an unbound key (empty bundle) works in any app', () async {
      final code = await _mint(kp,
          seconds: 60, kid: 'b3', expiresAt: now.add(const Duration(days: 1)));
      final parsed = await verifySignedVipKey(code,
          publicKeyBase64: pub, now: now, currentBundleId: 'com.anything');
      expect(parsed.bundleId, isNull);
    });

    test('an unknown bundle id skips the check rather than blocking', () async {
      // A host that cannot read its bundle id must still be able to redeem —
      // failing closed here would lock out legitimate users over a plugin
      // hiccup, and the signature and expiry are still enforced.
      final code = await _mint(kp,
          seconds: 60,
          kid: 'b4',
          expiresAt: now.add(const Duration(days: 1)),
          bundle: 'com.roy.app');
      final parsed = await verifySignedVipKey(code,
          publicKeyBase64: pub, now: now, currentBundleId: null);
      expect(parsed.bundleId, 'com.roy.app');
    });
  });

  group('AVP1 compatibility', () {
    test('an old AVP1 key still verifies, with no expiry or binding', () async {
      final code = await _mint(kp, seconds: 120, kid: 'old1', v1: true);
      final parsed = await verifySignedVipKey(code,
          publicKeyBase64: pub, now: now, currentBundleId: 'com.roy.app');
      expect(parsed.duration, const Duration(seconds: 120));
      expect(parsed.expiresAt, isNull);
      expect(parsed.bundleId, isNull);
    });

    test('an AVP1 payload relabelled as AVP2 is rejected (wrong field count)',
        () async {
      final code = await _mint(kp, seconds: 120, kid: 'old2', v1: true);
      final relabelled = code.replaceFirst('AVP1.', 'AVP2.');
      expect(
        () => verifySignedVipKey(relabelled, publicKeyBase64: pub, now: now),
        throwsA(isA<VipKeyException>()
            .having((e) => e.message, 'message', contains('payload shape'))),
      );
    });

    test('an unknown version prefix is rejected', () async {
      final code = await _mint(kp, seconds: 120, kid: 'old3', v1: true);
      expect(
        () => verifySignedVipKey(code.replaceFirst('AVP1.', 'AVP9.'),
            publicKeyBase64: pub, now: now),
        throwsA(isA<VipKeyException>()
            .having((e) => e.message, 'message', contains('bad format'))),
      );
    });
  });
}
