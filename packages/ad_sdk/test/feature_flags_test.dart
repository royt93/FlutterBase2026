import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('AdManager.applySignedFeatureFlags — round 62 audit fix: '
      'rollback guard survives a restart', () {
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      AdPreferences.resetForTest();
      AdManager().debugFeatureFlagsRevision = null;
    });

    tearDown(() {
      AdManager().debugFeatureFlagsRevision = null;
    });

    test('a stale revision is rejected even after the in-memory guard is '
        'lost — the shape a real app restart causes', () async {
      final (rev2, key) = await _signed(revision: 2);

      expect(
        await AdManager()
            .applySignedFeatureFlags(rev2, publicKeyBase64: key),
        isTrue,
        reason: 'sanity: revision 2 applies cleanly with no prior state',
      );

      // Simulate a real app restart: the in-memory guard is gone, but the
      // persisted revision (written by the successful apply above) is not.
      AdManager().debugFeatureFlagsRevision = null;

      final (rev1, key1) = await _signed(revision: 1);
      expect(
        await AdManager()
            .applySignedFeatureFlags(rev1, publicKeyBase64: key1),
        isFalse,
        reason: 'revision 1 is older than the already-applied revision 2 — '
            'the persisted revision must still reject it after the '
            'in-memory guard resets, or a stale-but-validly-signed, '
            'still-unexpired payload could replay indefinitely across '
            'cold starts',
      );
    });

    test('a newer revision after a restart is still accepted', () async {
      final (rev2, key) = await _signed(revision: 2);
      await AdManager().applySignedFeatureFlags(rev2, publicKeyBase64: key);

      AdManager().debugFeatureFlagsRevision = null;

      final (rev3, key3) = await _signed(revision: 3);
      expect(
        await AdManager()
            .applySignedFeatureFlags(rev3, publicKeyBase64: key3),
        isTrue,
      );
    });
  });

  // B: coverage — SignedFeatureFlags.fromJson malformed-input fall-safe paths
  // (lines 28-37: non-int revision → -1, bad expiresAt → epoch, non-Map flags → {}).
  group('SignedFeatureFlags.fromJson — malformed-input fail-safe', () {
    test('non-int revision falls back to -1', () {
      final f = SignedFeatureFlags.fromJson({
        'revision': 'bad',
        'expiresAt': '2030-01-01T00:00:00.000Z',
        'flags': <String, dynamic>{'x': true},
        'signatureBase64': '',
      });
      expect(f.revision, -1);
    });

    test('unparseable expiresAt falls back to epoch', () {
      final f = SignedFeatureFlags.fromJson({
        'revision': 1,
        'expiresAt': 'not-a-date',
        'flags': <String, dynamic>{'x': true},
        'signatureBase64': '',
      });
      expect(f.expiresAt.millisecondsSinceEpoch, 0);
    });

    test('null expiresAt falls back to epoch', () {
      final f = SignedFeatureFlags.fromJson({
        'revision': 1,
        'expiresAt': null,
        'flags': <String, dynamic>{'x': true},
        'signatureBase64': '',
      });
      expect(f.expiresAt.millisecondsSinceEpoch, 0);
    });

    test('non-Map flags falls back to empty map', () {
      final f = SignedFeatureFlags.fromJson({
        'revision': 1,
        'expiresAt': '2030-01-01T00:00:00.000Z',
        'flags': 'bad',
        'signatureBase64': 'abc',
      });
      expect(f.flags, isEmpty);
    });

    test('missing signatureBase64 falls back to empty string', () {
      final f = SignedFeatureFlags.fromJson({
        'revision': 1,
        'expiresAt': '2030-01-01T00:00:00.000Z',
        'flags': <String, dynamic>{},
      });
      expect(f.signatureBase64, '');
    });

    test('canonicalPayload round-trips through jsonDecode', () {
      final f = SignedFeatureFlags.fromJson({
        'revision': 5,
        'expiresAt': '2030-06-01T00:00:00.000Z',
        'flags': <String, dynamic>{'kill_banner': false},
        'signatureBase64': 'sig==',
      });
      final decoded = jsonDecode(f.canonicalPayload()) as Map<String, dynamic>;
      expect(decoded['revision'], 5);
      expect((decoded['flags'] as Map)['kill_banner'], false);
    });
  });
}
