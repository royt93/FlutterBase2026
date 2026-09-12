import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(SignedFeatureFlags, String)> _signed({
  int revision = 1,
  DateTime? expiresAt,
}) async {
  final algorithm = Ed25519();
  final pair = await algorithm.newKeyPair();
  final publicKey = await pair.extractPublicKey();
  final unsigned = SignedFeatureFlags(
    revision: revision,
    expiresAt:
        expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
    flags: const {'arbitrator': false, 'journeyPrefetcher': false},
    signatureBase64: '',
  );
  final signature = await algorithm
      .sign(utf8.encode(unsigned.canonicalPayload()), keyPair: pair);
  return (
    SignedFeatureFlags(
      revision: revision,
      expiresAt: unsigned.expiresAt,
      flags: unsigned.flags,
      signatureBase64: base64Url.encode(signature.bytes),
    ),
    base64Url.encode(publicKey.bytes)
  );
}

void main() {
  test('valid signature passes, expired and stale payloads fail', () async {
    final (valid, key) = await _signed();
    expect(await valid.verify(publicKeyBase64: key), isTrue);
    expect(
        await valid.verify(publicKeyBase64: key, previousRevision: 2), isFalse);
    final (expired, expiredKey) = await _signed(expiresAt: DateTime.utc(2020));
    expect(await expired.verify(publicKeyBase64: expiredKey), isFalse);
  });

  test('tampering or malformed key fails closed', () async {
    final (valid, key) = await _signed();
    final tampered = SignedFeatureFlags(
      revision: valid.revision,
      expiresAt: valid.expiresAt,
      flags: const {'arbitrator': true},
      signatureBase64: valid.signatureBase64,
    );
    expect(await tampered.verify(publicKeyBase64: key), isFalse);
    expect(await valid.verify(publicKeyBase64: 'bad'), isFalse);
  });
}
