// Round-25 QC round 22 (`codex`, MAJOR) — the signed CRL and the public key it
// was verified against are ONE fact and are now persisted as ONE value.
//
// Why it matters in the real world: as two separate SharedPreferences writes
// there was a window between them. A process death inside that window — or two
// `VipManager`s refreshing at once — left a CRL stored against a key it was not
// signed with. On the next launch the verify failed, and a failed verify is
// deliberately treated as "no revocations" (fail open). A key the publisher had
// revoked was redeemable again, forever, on that device.
//
// Every test below fails if the write is split back into two, or if the
// migration read is loosened.

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

/// The two legacy keys, spelled out here on purpose: if either name ever
/// changes, every device that upgraded from an older build silently loses its
/// cached CRL, and this test is the thing that notices.
const String _kLegacyRaw = 'ad_sdk_vip_revocation_cache_v1';
const String _kLegacyKey = 'ad_sdk_vip_revocation_pubkey_v1';

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
    final sig = await ed.sign(utf8.encode('CRL1|') + payload, keyPair: kp);
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

  late AdPreferences prefs;
  late SharedPreferences raw;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
    raw = await SharedPreferences.getInstance();
  });

  group('AdPreferences — the CRL cache is one value', () {
    // THE fix. Two writes = a window; one write = no window. Nothing else in
    // this file matters if this assertion goes red.
    test('storing the pair touches exactly one preference key', () async {
      final before = raw.getKeys().toSet();

      await prefs.setVipRevocationCache(raw: 'CRL1.aaa.bbb', publicKey: 'PUB');

      final written = raw.getKeys().toSet().difference(before);
      expect(written, hasLength(1),
          reason: 'a second key means a second await, and a second await means '
              'a window where a process death leaves the CRL paired with the '
              'wrong key — the exact fail-open this fix removes');
    });

    test('the pair reads back exactly as written', () async {
      await prefs.setVipRevocationCache(raw: 'CRL1.aaa.bbb', publicKey: 'PUB');
      final got = prefs.getVipRevocationCache();
      expect(got?.raw, 'CRL1.aaa.bbb');
      expect(got?.publicKey, 'PUB');
    });

    // Migration. Devices that already shipped have only the two legacy keys,
    // and losing their cached CRL means losing every revocation they know
    // about until the host next fetches one — which for an offline device is
    // never.
    test('a legacy two-key pair is still read after an upgrade', () async {
      await raw.setString(_kLegacyRaw, 'CRL1.legacy.sig');
      await raw.setString(_kLegacyKey, 'LEGACY_PUB');
      AdPreferences.resetForTest();
      prefs = await AdPreferences.getInstance();

      final got = prefs.getVipRevocationCache();
      expect(got?.raw, 'CRL1.legacy.sig');
      expect(got?.publicKey, 'LEGACY_PUB');
    });

    test('a half-written legacy pair is no pair at all', () async {
      await raw.setString(_kLegacyRaw, 'CRL1.legacy.sig');
      AdPreferences.resetForTest();
      prefs = await AdPreferences.getInstance();

      expect(prefs.getVipRevocationCache(), isNull,
          reason: 'a CRL with no key to verify it against is unusable — '
              'returning it would just push the failure one layer up');
    });

    // The migration must not be able to run backwards: once v2 exists, the
    // legacy keys are a stale snapshot of exactly the mismatched state v2
    // was introduced to end.
    test('a stale legacy pair never overrides the v2 value', () async {
      await raw.setString(_kLegacyRaw, 'CRL1.stale.sig');
      await raw.setString(_kLegacyKey, 'STALE_PUB');
      await prefs.setVipRevocationCache(raw: 'CRL1.new.sig', publicKey: 'NEW');

      final got = prefs.getVipRevocationCache();
      expect(got?.raw, 'CRL1.new.sig');
      expect(got?.publicKey, 'NEW');
    });

    test('a corrupt v2 value is a final answer, not a fallback to legacy',
        () async {
      await raw.setString(_kLegacyRaw, 'CRL1.stale.sig');
      await raw.setString(_kLegacyKey, 'STALE_PUB');
      await raw.setString('ad_sdk_vip_revocation_v2', '{not json');
      AdPreferences.resetForTest();
      prefs = await AdPreferences.getInstance();

      expect(prefs.getVipRevocationCache(), isNull,
          reason: 'falling back would resurrect the stale pair this whole '
              'change exists to stop');
    });
  });

  group('VipManager — the pair survives a relaunch and still revokes', () {
    late _FakeVipEntriesStore store;
    late SimpleKeyPair keyPair;
    late String pub;

    setUp(() async {
      store = _FakeVipEntriesStore(prefs);
      await VipManager(prefs, vipEntriesStore: store).revokeAll();
      keyPair = await ed.newKeyPair();
      pub = await pubB64(keyPair);
    });

    test('a refresh caches a pair a fresh launch can verify and apply',
        () async {
      final crl = await mintCrl(keyPair,
          issuedAtEpoch: 7000, kids: ['leaked-after-restart']);
      final code = await mintVipKey(keyPair,
          seconds: const Duration(days: 30).inSeconds,
          kid: 'leaked-after-restart');

      final first = VipManager(prefs, vipEntriesStore: store);
      await first.load();
      expect((await first.redeemSignedKey(code, publicKeyBase64: pub)).status,
          VipRedeemStatus.success);
      final fullLength = await store.getRaw();
      await first.refreshRevocationList(
        publicKeyBase64: pub,
        revocationProvider: _FakeRevocationProvider(crl),
      );
      first.dispose();

      // The crash: the clamped entries never landed, only the cached pair did.
      await store.setRaw(fullLength!);

      // Next launch. No network, no refresh — the cached pair is the only
      // thing standing between a revoked key and a permanent VIP.
      final second = VipManager(prefs, vipEntriesStore: store);
      await second.load();
      addTearDown(second.dispose);
      expect(second.expiresAt!.difference(DateTime.now()).inHours,
          lessThanOrEqualTo(24),
          reason: 'the CRL must still verify against the key it was stored '
              'with; if the pair can be crossed, this grant runs its full 30 '
              'days');
    });

    // The old failure mode, pinned so nobody re-creates it: a crossed pair
    // fails open. This is what a torn two-write left behind.
    test('CONTROL — a crossed pair fails open, which is why it must be one '
        'write', () async {
      final other = await ed.newKeyPair();
      final crl =
          await mintCrl(keyPair, issuedAtEpoch: 7100, kids: ['crossed']);
      final code = await mintVipKey(keyPair,
          seconds: const Duration(days: 30).inSeconds, kid: 'crossed');

      final first = VipManager(prefs, vipEntriesStore: store);
      await first.load();
      expect((await first.redeemSignedKey(code, publicKeyBase64: pub)).status,
          VipRedeemStatus.success);
      first.dispose();

      // CRL signed by `keyPair`, stored against `other`'s public key — the
      // exact state a process death between two writes used to produce.
      await prefs.setVipRevocationCache(
          raw: crl, publicKey: await pubB64(other));

      final second = VipManager(prefs, vipEntriesStore: store);
      await second.load();
      addTearDown(second.dispose);
      expect(second.expiresAt!.difference(DateTime.now()).inDays,
          greaterThanOrEqualTo(29),
          reason: 'a mismatched pair cannot be verified, and an unverifiable '
              'CRL is ignored by design — so the revoked grant keeps running. '
              'That consequence is the reason the pair is written atomically');
    });
  });
}
