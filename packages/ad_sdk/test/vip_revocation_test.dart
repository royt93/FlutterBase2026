// T95 — Flagship: VIP key revocation list (CRL), signed offline with the
// same Ed25519 key as VIP keys themselves.
//
// Unit: verifySignedCrl accepts genuine CRLs, rejects tampered / wrong-key /
// malformed ones. Integration: VipManager.refreshRevocationList fetches +
// verifies + caches, fails open on every error, and VipManager.redeemSignedKey
// rejects a `kid` once it's revoked.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory fake so VIP tests don't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

class _FakeRevocationProvider implements VipRevocationProvider {
  _FakeRevocationProvider(this._code);
  final Object? _code; // String, or an Exception to throw, or null

  @override
  Future<String?> fetchSignedCrl() async {
    if (_code is Exception) throw _code;
    return _code as String?;
  }
}

void main() {
  final ed = Ed25519();

  Future<String> pubB64(SimpleKeyPair kp) async =>
      base64Url.encode((await kp.extractPublicKey()).bytes);

  Future<String> mintCrl(
    SimpleKeyPair kp, {
    required int issuedAtEpoch,
    required List<String> kids,
  }) async {
    final payload = utf8.encode('$issuedAtEpoch|${kids.join(',')}');
    final sig = await ed.sign(payload, keyPair: kp);
    return 'CRL1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  Future<String> mintVipKey(
    SimpleKeyPair kp, {
    required int seconds,
    required String kid,
  }) async {
    final expiresAt =
        DateTime.now().toUtc().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
            1000;
    final payload = utf8.encode('$seconds|$kid|$expiresAt|');
    final sig = await ed.sign(payload, keyPair: kp);
    return 'AVP2.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  group('verifySignedCrl', () {
    late SimpleKeyPair keyPair;
    late String pub;

    setUp(() async {
      keyPair = await ed.newKeyPair();
      pub = await pubB64(keyPair);
    });

    test('accepts a genuine CRL and decodes issuedAt + revoked kids',
        () async {
      final code = await mintCrl(keyPair,
          issuedAtEpoch: 1000000, kids: ['a', 'b', 'c']);
      final result = await verifySignedCrl(code, publicKeyBase64: pub);
      expect(result.revokedKeyIds, {'a', 'b', 'c'});
      expect(result.issuedAt,
          DateTime.fromMillisecondsSinceEpoch(1000000000, isUtc: true));
    });

    test('accepts an empty kid list (a CRL that revokes nothing)', () async {
      final code =
          await mintCrl(keyPair, issuedAtEpoch: 1000000, kids: []);
      final result = await verifySignedCrl(code, publicKeyBase64: pub);
      expect(result.revokedKeyIds, isEmpty);
    });

    test('accepts when the public key is a rotation list containing it',
        () async {
      final code = await mintCrl(keyPair, issuedAtEpoch: 1, kids: ['x']);
      final other = await ed.newKeyPair();
      final rotationList = '${await pubB64(other)},$pub';
      final result =
          await verifySignedCrl(code, publicKeyBase64: rotationList);
      expect(result.revokedKeyIds, {'x'});
    });

    test('rejects tampered payload', () async {
      final code = await mintCrl(keyPair, issuedAtEpoch: 1, kids: ['a']);
      final parts = code.split('.');
      final forged =
          'CRL1.${base64Url.encode(utf8.encode('1|z'))}.${parts[2]}';
      expect(
        () => verifySignedCrl(forged, publicKeyBase64: pub),
        throwsA(isA<VipKeyException>()),
      );
    });

    test('rejects CRL signed by a different private key', () async {
      final other = await ed.newKeyPair();
      final code = await mintCrl(other, issuedAtEpoch: 1, kids: ['x']);
      expect(
        () => verifySignedCrl(code, publicKeyBase64: pub),
        throwsA(isA<VipKeyException>()),
      );
    });

    test('rejects malformed / wrong-prefix / garbage', () async {
      for (final bad in <String>[
        'not-a-crl',
        'CRL1.only-two',
        'AVP1.${base64Url.encode(utf8.encode('1|x'))}.AAAA',
        '',
      ]) {
        expect(
          () => verifySignedCrl(bad, publicKeyBase64: pub),
          throwsA(isA<VipKeyException>()),
          reason: 'should reject "$bad"',
        );
      }
    });
  });

  group('VipManager revocation', () {
    late AdPreferences prefs;
    late _FakeVipEntriesStore store;
    late SimpleKeyPair keyPair;
    late String pub;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await AdPreferences.getInstance();
      store = _FakeVipEntriesStore(prefs);
      await VipManager(prefs, vipEntriesStore: store).revokeAll();
      keyPair = await ed.newKeyPair();
      pub = await pubB64(keyPair);
    });

    test('a key whose kid is on the fetched CRL is rejected', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final crl =
          await mintCrl(keyPair, issuedAtEpoch: 1000, kids: ['blocked']);
      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );

      final code =
          await mintVipKey(keyPair, seconds: 3600, kid: 'blocked');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);

      expect(r.status, VipRedeemStatus.invalid);
      expect(mgr.isActive, isFalse);
    });

    test('a kid NOT on the CRL still redeems successfully', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final crl =
          await mintCrl(keyPair, issuedAtEpoch: 1000, kids: ['other-kid']);
      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );

      final code = await mintVipKey(keyPair, seconds: 3600, kid: 'clean');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);

      expect(r.status, VipRedeemStatus.success);
      expect(mgr.isActive, isTrue);
    });

    test('fails open when the provider throws', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider:
            _FakeRevocationProvider(Exception('network down')),
      );

      final code = await mintVipKey(keyPair, seconds: 3600, kid: 'unaffected');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.success,
          reason: 'a fetch failure must never block redemption');
    });

    test('fails open when the provider returns null', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(null),
      );

      final code = await mintVipKey(keyPair, seconds: 3600, kid: 'unaffected2');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.success);
    });

    test('fails open when the fetched CRL has a bad signature', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final other = await ed.newKeyPair();
      final badCrl =
          await mintCrl(other, issuedAtEpoch: 1000, kids: ['should-not-apply']);
      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(badCrl),
      );

      final code = await mintVipKey(keyPair,
          seconds: 3600, kid: 'should-not-apply');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.success,
          reason: 'an unverifiable CRL must never be applied');
    });

    test('an older (replayed) CRL is ignored once a newer one is cached',
        () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final newerCrl =
          await mintCrl(keyPair, issuedAtEpoch: 2000, kids: ['newly-blocked']);
      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(newerCrl),
      );

      // An attacker (or a stale CDN cache) replays an OLDER, empty CRL that
      // doesn't list the newer revocation.
      final olderCrl = await mintCrl(keyPair, issuedAtEpoch: 1000, kids: []);
      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(olderCrl),
      );

      final code =
          await mintVipKey(keyPair, seconds: 3600, kid: 'newly-blocked');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.invalid,
          reason: 'the older replayed CRL must not undo the newer revocation');
    });

    test(
        'a cached, verified revocation list survives a fresh VipManager '
        'instance (simulated app restart), without calling refreshRevocationList '
        'again', () async {
      final mgr1 = VipManager(prefs, vipEntriesStore: store);
      await mgr1.load();

      final crl = await mintCrl(keyPair,
          issuedAtEpoch: 1000, kids: ['persisted-block']);
      await mgr1.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );
      mgr1.dispose();

      final mgr2 = VipManager(prefs, vipEntriesStore: store);
      await mgr2.load();
      addTearDown(mgr2.dispose);

      final code =
          await mintVipKey(keyPair, seconds: 3600, kid: 'persisted-block');
      final r = await mgr2.redeemSignedKey(code, publicKeyBase64: pub);

      expect(r.status, VipRedeemStatus.invalid,
          reason:
              'the cached signed CRL must be re-verified and applied on a '
              'fresh instance, not require a fresh fetch');
    });
  });
}
