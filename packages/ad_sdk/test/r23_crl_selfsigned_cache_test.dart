// Round-23 QC (reviewer C, MAJOR) — a CRL cache nobody trustworthy vouched for
// must not be able to lock out every real CRL.
//
// The startup path in `VipManager.load()` has no host public key of its own, so
// it verifies the cached CRL against the key stored beside it in the same
// plaintext preferences record. That is self-attesting. Anyone who can write
// preferences — a rooted device, which is exactly the population that redeems a
// leaked, refunded or resold key — mints their own Ed25519 pair, signs an empty
// CRL dated in 2286, and writes both. It verifies. `_revocationIssuedAt`
// latches to 2286, and `refreshRevocationList`'s "only accept a newer
// `issuedAt`" rule then rejects every CRL the publisher will ever issue.
// Revocation is permanently dead on that device.
//
// The fix withholds only the `issuedAt` latch until a host key has confirmed
// the cache. The revoked SET from an untrusted cache is still applied, because
// it can only ever narrow a grant — round-7's offline startup clamp keeps
// working unchanged.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  final String? _code;
  @override
  Future<String?> fetchSignedCrl() async => _code;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ed = Ed25519();

  Future<String> pubB64(SimpleKeyPair kp) async =>
      base64Url.encode((await kp.extractPublicKey()).bytes);

  Future<String> mintCrl(
    SimpleKeyPair kp, {
    required int issuedAtEpoch,
    required List<String> kids,
  }) async {
    final payload = utf8.encode('$issuedAtEpoch|${kids.join(',')}');
    final signedMessage = utf8.encode('CRL1|') + payload;
    final sig = await ed.sign(signedMessage, keyPair: kp);
    return 'CRL1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  Future<String> mintVipKey(
    SimpleKeyPair kp, {
    required int seconds,
    required String kid,
  }) async {
    final expiresAt = DateTime.now()
            .toUtc()
            .add(const Duration(days: 30))
            .millisecondsSinceEpoch ~/
        1000;
    final payload = utf8.encode('$seconds|$kid|$expiresAt|');
    final sig = await ed.sign(payload, keyPair: kp);
    return 'AVP2.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  // 2286-ish, well past anything the publisher will ever stamp.
  const farFutureEpoch = 9999999999;

  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    // `AdPreferences` caches its SharedPreferences handle in a static, so
    // resetting only the mock store leaves the previous test's CRL cache
    // readable through the stale instance — and a leaked cache is exactly what
    // these tests manipulate.
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
  });

  test(
      'a self-signed far-future cache cannot veto the publisher\'s real CRL',
      () async {
    final attacker = await ed.newKeyPair();
    final publisher = await ed.newKeyPair();
    final publisherPub = await pubB64(publisher);

    // The attacker's forged cache: their own key, dated in 2286, revoking
    // nothing. Written straight into preferences, as a rooted device can.
    await prefs.setVipRevocationCache(
      raw: await mintCrl(attacker, issuedAtEpoch: farFutureEpoch, kids: []),
      publicKey: await pubB64(attacker),
    );

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load(); // reads the forged cache under its own key
    addTearDown(mgr.dispose);

    // The publisher issues a genuine CRL revoking the leaked key. Today's date
    // is, of course, "older" than 2286.
    final realCrl =
        await mintCrl(publisher, issuedAtEpoch: 1750000000, kids: ['LEAKED']);
    await mgr.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _FakeRevocationProvider(realCrl),
    );

    // THE finding: the real CRL has to take effect anyway.
    final result = await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: 86400, kid: 'LEAKED'),
      publicKeyBase64: publisherPub,
    );
    expect(result.ok, isFalse,
        reason: 'a revoked key must not redeem — the forged cache locked the '
            'publisher out of revocation entirely before this fix');
    expect(mgr.isActive, isFalse);
  });

  test('the untrusted cache is still APPLIED — it can only ever narrow',
      () async {
    final attacker = await ed.newKeyPair();
    final publisher = await ed.newKeyPair();
    final publisherPub = await pubB64(publisher);

    await prefs.setVipRevocationCache(
      raw: await mintCrl(attacker,
          issuedAtEpoch: farFutureEpoch, kids: ['SOMEKID']),
      publicKey: await pubB64(attacker),
    );

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    // Round-7's offline startup clamp depends on this still working: the set
    // from a cache verified under its own key is honoured, because honouring it
    // costs an attacker their own entitlement and buys them nothing.
    final result = await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: 86400, kid: 'SOMEKID'),
      publicKeyBase64: publisherPub,
    );
    expect(result.ok, isFalse,
        reason: 'withholding the issuedAt latch must not turn off the revoked '
            'set the startup path loads');
  });

  test(
      'CONTROL — replay protection still holds once a host key has vouched for '
      'the cache', () async {
    final publisher = await ed.newKeyPair();
    final publisherPub = await pubB64(publisher);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    // A genuine, current CRL revoking A.
    await mgr.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _FakeRevocationProvider(
          await mintCrl(publisher, issuedAtEpoch: 1750000000, kids: ['A'])),
    );

    // An attacker replays an OLDER genuine CRL from before A was revoked. It
    // verifies under the real key, so only the issuedAt comparison stops it.
    await mgr.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _FakeRevocationProvider(
          await mintCrl(publisher, issuedAtEpoch: 1700000000, kids: [])),
    );

    final result = await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: 86400, kid: 'A'),
      publicKeyBase64: publisherPub,
    );
    expect(result.ok, isFalse,
        reason: 'the replayed older CRL must not un-revoke A — this is the '
            'guard the fix narrows, and it has to survive intact');
  });

  test('CONTROL — a normal cache written by the real key still latches',
      () async {
    final publisher = await ed.newKeyPair();
    final publisherPub = await pubB64(publisher);

    // Session 1 caches a genuine CRL through the normal path.
    final first = VipManager(prefs, vipEntriesStore: store);
    await first.load();
    await first.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _FakeRevocationProvider(
          await mintCrl(publisher, issuedAtEpoch: 1750000000, kids: ['B'])),
    );
    first.dispose();

    // Session 2 reads it back at startup and then sees a replayed older CRL.
    final second = VipManager(prefs, vipEntriesStore: store);
    await second.load();
    addTearDown(second.dispose);
    await second.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _FakeRevocationProvider(
          await mintCrl(publisher, issuedAtEpoch: 1700000000, kids: [])),
    );

    final result = await second.redeemSignedKey(
      await mintVipKey(publisher, seconds: 86400, kid: 'B'),
      publicKeyBase64: publisherPub,
    );
    expect(result.ok, isFalse,
        reason: 'across a restart, a genuinely cached CRL must still refuse a '
            'replayed older one');
  });

  // Round-31 QC (reviewer B) — every test above asserts `result.ok == false`,
  // i.e. only the SAFE direction: the hostile cache does not GRANT anything.
  // None of them checked the direction this fix actually protects — that a
  // poisoned `issuedAt` latch cannot WEDGE REVOCATION OFF. Poisoning the latch
  // on the failed-verify path left the whole file green while every genuine CRL
  // that ever arrived was rejected as "not newer" and a revoked key kept
  // redeeming for the life of the install.

  test('a genuine CRL is still ACCEPTED after a forged future-dated cache',
      () async {
    final publisher = await ed.newKeyPair();
    final publisherPub = await pubB64(publisher);
    final attacker = await ed.newKeyPair();

    // The attack: an empty CRL dated in 2286, self-signed, written straight
    // into preferences with its own key beside it.
    await prefs.setVipRevocationCache(
      raw: await mintCrl(attacker, issuedAtEpoch: 9999999999, kids: const []),
      publicKey: await pubB64(attacker),
    );

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    // The publisher revokes a key. Its issuedAt is now — older than 2286.
    await mgr.refreshRevocationList(
      publicKeyBase64: publisherPub,
      revocationProvider: _FakeRevocationProvider(await mintCrl(publisher,
          issuedAtEpoch: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          kids: ['WEDGED'])),
    );

    final revoked = await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: 86400, kid: 'WEDGED'),
      publicKeyBase64: publisherPub,
    );
    expect(revoked.ok, isFalse,
        reason: 'THE finding this fix is FOR — if the forged 2286 latch stood, '
            'no CRL the publisher ever issues would be accepted again and this '
            'revoked key would redeem for the life of the install');

    // And the same list must still let an unrevoked key through, or "revocation
    // works" would be indistinguishable from "everything is refused".
    final fine = await mgr.redeemSignedKey(
      await mintVipKey(publisher, seconds: 86400, kid: 'CLEAN'),
      publicKeyBase64: publisherPub,
    );
    expect(fine.ok, isTrue,
        reason: 'CONTROL — the accepted CRL narrows, it does not close');
  });
}
