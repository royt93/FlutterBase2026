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
    // Domain-separated: sign "CRL1|" + payload, not payload alone — see
    // signed_vip_key.dart's _crlSignedMessage doc comment for why.
    final signedMessage = utf8.encode('CRL1|') + payload;
    final sig = await ed.sign(signedMessage, keyPair: kp);
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

    // Security regression: a CRL is designed to be broadcast PUBLICLY (any
    // device fetches it, no secrecy requirement), so if its signature were
    // over the raw payload alone (no domain separation from the VIP-key
    // format), anyone who observed one could relabel its prefix from CRL1
    // to AVP1 and redeem it as a real VIP key — a CRL's
    // "<issuedAtEpoch>|<kids>" shape splits into exactly the same 2
    // pipe-delimited fields as AVP1's "<seconds>|<kid>" shape.
    //
    // 2026-08-17 fork-review note: this direction's protection is an
    // inherent property of Ed25519 (exact-byte verification) once mintCrl
    // signs "CRL1|"+payload — verifySignedVipKey (AVP1) itself was never
    // touched by the fix, so this test doesn't regress if _crlSignedMessage
    // is reverted. The test that actually pins the production fix is the
    // reverse direction below (a genuine AVP1 key relabeled as a CRL,
    // verified through the real verifySignedCrl).
    test(
        'a genuine CRL cannot be relabeled as an AVP1 key and redeemed for '
        'VIP (domain separation)', () async {
      final crl = await mintCrl(keyPair,
          issuedAtEpoch: 1766000000, kids: ['whatever']);
      final parts = crl.split('.');
      final forgedAsVipKey = 'AVP1.${parts[1]}.${parts[2]}';

      expect(
        () => verifySignedVipKey(forgedAsVipKey, publicKeyBase64: pub),
        throwsA(isA<VipKeyException>()),
        reason:
            "a CRL's signature must not verify as a valid AVP1 key signature "
            'over the same payload bytes',
      );
    });

    test(
        'a genuine AVP1 VIP key cannot be relabeled as a CRL and applied as '
        'a revocation list', () async {
      // AVP1's raw "<seconds>|<kid>" shape is the exact 2-field shape that
      // collides with CRL's "<issuedAt>|<kids>" — mint the actual AVP1
      // format directly (mintVipKey above mints AVP2, which isn't the
      // colliding shape).
      final avp1Payload = utf8.encode('3600|x');
      final avp1Sig = await ed.sign(avp1Payload, keyPair: keyPair);
      final vipKey =
          'AVP1.${base64Url.encode(avp1Payload)}.${base64Url.encode(avp1Sig.bytes)}';
      final parts = vipKey.split('.');
      final forgedAsCrl = 'CRL1.${parts[1]}.${parts[2]}';

      expect(
        () => verifySignedCrl(forgedAsCrl, publicKeyBase64: pub),
        throwsA(isA<VipKeyException>()),
        reason:
            'an AVP1 key signature must not verify as a valid CRL signature '
            'over the same payload bytes',
      );
    });
  });

  group('VipManager revocation', () {
    late AdPreferences prefs;
    late _FakeVipEntriesStore store;
    late SimpleKeyPair keyPair;
    late String pub;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // Round-7 — without this the cached AdPreferences singleton (and its
      // in-memory copy of the previous test's values) survives
      // `setMockInitialValues`, so a CRL cached by one test leaked into the
      // next. That used to be harmless only because each test mints a fresh
      // keypair and the leaked CRL then failed to verify; now that `load()`
      // applies the cached CRL with the key it was verified against, the leak
      // is load-bearing and has to go.
      AdPreferences.resetForTest();
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

    // M5 (round-6 audit, corroborated by three reviewers) — `_revokedKeyIds`
    // was consulted at exactly one place: redemption. Applying a newer CRL
    // swapped the set and cached it, and did nothing else. So a key that
    // leaked AFTER being redeemed on N devices kept its full window on all N
    // of them; revocation only ever stopped the (N+1)-th redemption.
    //
    // Clamping rather than deleting is deliberate. A mis-issued CRL is not
    // recoverable from the customer's side, so deleting would mean one bad
    // publish silently strips VIP from people who paid. Clamping to 24h makes
    // a mis-issue cost a paying customer one day — with a window for support
    // to re-issue — while a leaked key stops earning within a day.
    // Round-9 follow-up. `_save()` now drops writes from a disposed manager, so
    // a redeem on a stale reference used to grant nothing while still burning
    // the key at the one-time-use ledger: the customer's code is spent forever
    // and they have no VIP. Refuse before touching the ledger instead.
    test('a redeem on a disposed manager does not burn the key', () async {
      final dead = VipManager(prefs, vipEntriesStore: store);
      await dead.load();
      final code = await mintVipKey(keyPair, seconds: 3600, kid: 'not-burned');
      dead.dispose();

      final refused = await dead.redeemSignedKey(code, publicKeyBase64: pub);
      expect(refused.ok, isFalse);

      // The key must still work on the manager that replaces it.
      final fresh = VipManager(prefs, vipEntriesStore: store);
      await fresh.load();
      addTearDown(fresh.dispose);
      final r = await fresh.redeemSignedKey(code, publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.success,
          reason: 'the key was never actually spent, so it must still redeem');
      expect(fresh.isActive, isTrue);
    });

    test('applying a CRL clamps a VIP already granted by that kid', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      // Redeemed while the key was still good: a 30-day grant.
      final code = await mintVipKey(keyPair,
          seconds: const Duration(days: 30).inSeconds, kid: 'leaked');
      final r = await mgr.redeemSignedKey(code, publicKeyBase64: pub);
      expect(r.status, VipRedeemStatus.success);
      expect(mgr.isActive, isTrue);
      final grantedUntil = mgr.expiresAt!;
      expect(grantedUntil.difference(DateTime.now()).inDays, greaterThan(20));

      // The key leaks and is revoked.
      final crl = await mintCrl(keyPair, issuedAtEpoch: 2000, kids: ['leaked']);
      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );

      final after = mgr.expiresAt;
      expect(after, isNotNull,
          reason: 'clamped, NOT deleted — a mis-issued CRL must not strip a '
              'paying customer outright');
      expect(after!.isBefore(grantedUntil), isTrue,
          reason: 'the 30-day window must have been cut short');
      expect(after.difference(DateTime.now()).inHours, lessThanOrEqualTo(24),
          reason: 'a revoked key stops earning within a day');
    });

    // Round-6 codex QC — the clamp ran AFTER the CRL was persisted, so a
    // process death between those two awaits left the CRL cached and the grant
    // untouched. On the next launch the same-age CRL hits the "not newer"
    // branch and returns before the clamp, so that grant was never clamped
    // again — permanently. This drives the recovery path directly: a cached
    // CRL plus an unclamped grant, i.e. exactly the state a crash leaves.
    test('a cached CRL still clamps a grant that was missed (crash recovery)',
        () async {
      // First manager: redeem, then cache a CRL revoking that kid, but do NOT
      // let the clamp persist — simulated by re-reading into a fresh manager
      // whose entries came straight from the store.
      final crl = await mintCrl(keyPair, issuedAtEpoch: 3000, kids: ['leaked-crash']);
      final code = await mintVipKey(keyPair,
          seconds: const Duration(days: 30).inSeconds, kid: 'leaked-crash');

      final first = VipManager(prefs, vipEntriesStore: store);
      await first.load();
      expect((await first.redeemSignedKey(code, publicKeyBase64: pub)).status,
          VipRedeemStatus.success);
      first.dispose();

      // The crash state: CRL is in the cache, the grant on disk is full-length.
      await prefs.setVipRevocationCacheRaw(crl);

      final second = VipManager(prefs, vipEntriesStore: store);
      await second.load();
      addTearDown(second.dispose);
      expect(second.isActive, isTrue, reason: 'sanity: grant survived reload');

      // Any path that consults the cached CRL must also repair the miss.
      await second.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );

      final remaining = second.expiresAt!.difference(DateTime.now());
      expect(remaining.inHours, lessThanOrEqualTo(24),
          reason: 'a grant the crash left unclamped must still get clamped, '
              'not stay full-length forever because the CRL is no longer new');
    });

    // Round-7 audit, MAJOR — every path that applied the CRL to grants ALREADY
    // on disk went through `refreshRevocationList` (or a redemption). A plain
    // startup did not: `load()` read the entries and never looked at the cached
    // CRL. So the state a crash leaves — CRL cached, grant still full-length —
    // survived launch after launch for any host that refreshes daily rather
    // than every boot, or any device that is offline when it launches. The test
    // above only proved the refresh path repairs it.
    test('a cached CRL clamps a missed grant on startup, with no refresh at all',
        () async {
      final crl =
          await mintCrl(keyPair, issuedAtEpoch: 4000, kids: ['leaked-startup']);
      final code = await mintVipKey(keyPair,
          seconds: const Duration(days: 30).inSeconds, kid: 'leaked-startup');

      final first = VipManager(prefs, vipEntriesStore: store);
      await first.load();
      expect((await first.redeemSignedKey(code, publicKeyBase64: pub)).status,
          VipRedeemStatus.success);
      // The grant as it sits on disk before any clamp touches it.
      final fullLength = await store.getRaw();
      await first.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );
      first.dispose();

      // The crash: the CRL is cached, but the clamped entries never landed.
      await store.setRaw(fullLength!);

      // Second launch. The host does NOT refresh — offline, or it only
      // refreshes once a day and today's call has not happened yet.
      final second = VipManager(prefs, vipEntriesStore: store);
      await second.load();
      second.dispose();
      expect(second.expiresAt!.difference(DateTime.now()).inHours,
          lessThanOrEqualTo(24),
          reason: 'a revoked key must stop earning within a day even on a '
              'device that never fetches another CRL');

      // Third launch, still no refresh: the clamp has to hold, not oscillate.
      final third = VipManager(prefs, vipEntriesStore: store);
      await third.load();
      addTearDown(third.dispose);
      expect(third.expiresAt!.difference(DateTime.now()).inHours,
          lessThanOrEqualTo(24));
    });

    test('applying a CRL leaves an unrelated VIP grant alone', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final code = await mintVipKey(keyPair,
          seconds: const Duration(days: 30).inSeconds, kid: 'innocent');
      expect((await mgr.redeemSignedKey(code, publicKeyBase64: pub)).status,
          VipRedeemStatus.success);
      final grantedUntil = mgr.expiresAt!;

      final crl =
          await mintCrl(keyPair, issuedAtEpoch: 2000, kids: ['some-other-kid']);
      await mgr.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );

      expect(mgr.expiresAt, grantedUntil,
          reason: 'revoking one kid must not touch grants from other keys — '
              'without this the clamp could quietly punish everyone');
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
