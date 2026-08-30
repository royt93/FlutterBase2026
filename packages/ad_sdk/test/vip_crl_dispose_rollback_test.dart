// Round-25 QC round 19 — a torn-down manager must not roll back revocations.
//
// `refreshRevocationList` awaits a NETWORK fetch, and it persists through
// `_prefs` directly, so `_save()`'s disposed guard does not cover it. A manager
// the host discarded mid-fetch used to resume, compare the fetched CRL against
// its OWN `_revocationIssuedAt` (which never saw the newer CRL the replacement
// manager had already cached), accept the older list, and write it over the
// newer one.
//
// Real consequence: a revoked key — leaked, refunded, resold — becomes
// redeemable again on the next launch. The revocation list is the only lever the
// SDK owner has over a key that is already in the wild, and it must not be
// undoable by an ordinary destroy/re-init.
import 'dart:async';
import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _ed = Ed25519();

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

class _BlockingVipEntriesStore extends _FakeVipEntriesStore {
  _BlockingVipEntriesStore(super.prefs);

  /// Held open so a test can park the clamp's write and tear the manager down
  /// while it is suspended there.
  Completer<void>? blockNextWrite;
  Completer<void>? nextWriteStarted;

  @override
  Future<void> setRaw(String json) async {
    final block = blockNextWrite;
    if (block != null) {
      blockNextWrite = null;
      nextWriteStarted?.complete();
      await block.future;
    }
    await super.setRaw(json);
  }
}

class _Crl implements VipRevocationProvider {
  _Crl(this.pending);
  final Future<String?> pending;
  @override
  Future<String?> fetchSignedCrl() => pending;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair keyPair;
  late String pub;
  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdPreferences.resetForTest();
    VipManager.resetSaveQueueForTest();
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
    keyPair = await _ed.newKeyPair();
    pub = base64Url.encode((await keyPair.extractPublicKey()).bytes);
  });

  tearDown(() => AdManager().debugVipManager = null);

  // Domain-separated exactly like production: sign "CRL1|" + payload.
  Future<String> crl(int issuedAt, List<String> kids) async {
    final payload = utf8.encode('$issuedAt|${kids.join(',')}');
    final sig = await _ed.sign(utf8.encode('CRL1|') + payload, keyPair: keyPair);
    return 'CRL1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  Future<String> key(String kid) async {
    final payload = utf8.encode('3600|$kid');
    final sig = await _ed.sign(payload, keyPair: keyPair);
    return 'AVP1.${base64Url.encode(payload)}.${base64Url.encode(sig.bytes)}';
  }

  /// What the app does on the launch after the race: fresh manager, reads the
  /// cached CRL off disk, and is asked to redeem the revoked key.
  Future<VipRedeemStatus> statusAfterRestart(String kid) async {
    final next = VipManager(prefs,
        vipEntriesStore: store, isConnectedCheck: () => true);
    await next.load();
    addTearDown(next.dispose);
    final r = await next.redeemSignedKey(await key(kid), publicKeyBase64: pub);
    return r.status;
  }

  group('a CRL fetch that outlives dispose() cannot undo a revocation', () {
    test(
        'dispose during the grant-clamp await cannot roll the CRL back either',
        () async {
      // Round 20: the round-19 guard is NOT the last await on this path.
      // `_clampRevokedEntries()` writes the entries store, and a manager parked
      // in that write can be disposed, resume, and still reach the two `_prefs`
      // writes below it. Reviewer's own reproducer, adopted verbatim in shape.
      final blockingStore = _BlockingVipEntriesStore(prefs);
      final dying = VipManager(prefs,
          vipEntriesStore: blockingStore, isConnectedCheck: () => true);
      await dying.load();
      // A grant the incoming CRL revokes — that is what makes the clamp write.
      await dying.addVip(
          key: 'SIGNED_old-grant', duration: const Duration(days: 30));

      final releaseClamp = Completer<void>();
      final clampStarted = Completer<void>();
      blockingStore
        ..blockNextWrite = releaseClamp
        ..nextWriteStarted = clampStarted;
      final stale = dying.refreshRevocationList(
          publicKeyBase64: pub,
          revocationProvider: _Crl(Future<String?>.value(
              await crl(1000, const <String>['old-grant']))));
      await clampStarted.future;

      dying.dispose();
      final live = VipManager(prefs,
          vipEntriesStore: _FakeVipEntriesStore(prefs),
          isConnectedCheck: () => true);
      addTearDown(live.dispose);
      final newer = await crl(2000, const <String>['resold-key']);
      await live.refreshRevocationList(
          publicKeyBase64: pub,
          revocationProvider: _Crl(Future<String?>.value(newer)));
      expect(prefs.getVipRevocationCache()?.raw, newer);

      releaseClamp.complete();
      await stale;

      expect(prefs.getVipRevocationCache()?.raw, newer,
          reason: 'the disposed manager resumed after its clamp write and must '
              'not overwrite the live manager\'s newer CRL');
      expect(await statusAfterRestart('resold-key'), VipRedeemStatus.invalid,
          reason: 'the live manager revoked this leaked/resold key; a stale '
              'continuation must not make it redeemable after restart');
    });

    test('the newer CRL persisted by the replacement manager survives',
        () async {
      final slowFetch = Completer<String?>();
      final dying = VipManager(prefs,
          vipEntriesStore: store, isConnectedCheck: () => true);
      await dying.load();
      final stale = dying.refreshRevocationList(
          publicKeyBase64: pub, revocationProvider: _Crl(slowFetch.future));

      // Host tears the SDK down while that fetch is still in flight, then
      // re-initialises — an ordinary provider switch or consent withdrawal.
      dying.dispose();
      final live = VipManager(prefs,
          vipEntriesStore: store, isConnectedCheck: () => true);
      await live.load();
      addTearDown(live.dispose);
      await live.refreshRevocationList(
          publicKeyBase64: pub,
          revocationProvider: _Crl(Future<String?>.value(
              await crl(2000, const <String>['resold-key']))));

      // Only now does the discarded manager's fetch answer, with an OLDER,
      // empty list.
      slowFetch.complete(await crl(1000, const <String>[]));
      await stale;

      expect(await statusAfterRestart('resold-key'), VipRedeemStatus.invalid,
          reason: 'a key the SDK owner revoked must stay revoked across a '
              'destroy/re-init — this is the only lever over a key already in '
              'the wild');
    });

    test('CONTROL — a live manager still applies a newer CRL it fetches',
        () async {
      // Without this, the test above would pass just as happily if the fix had
      // stopped `refreshRevocationList` persisting anything at all, which would
      // disable revocation entirely.
      final mgr = VipManager(prefs,
          vipEntriesStore: store, isConnectedCheck: () => true);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.refreshRevocationList(
          publicKeyBase64: pub,
          revocationProvider: _Crl(Future<String?>.value(
              await crl(3000, const <String>['revoked-live']))));

      final blocked = await mgr
          .redeemSignedKey(await key('revoked-live'), publicKeyBase64: pub);
      expect(blocked.status, VipRedeemStatus.invalid,
          reason: 'the fetched CRL must actually take effect in the running '
              'manager');
      expect(await statusAfterRestart('revoked-live'), VipRedeemStatus.invalid,
          reason: 'and must be on disk for the next launch');

      final unrelated =
          await mgr.redeemSignedKey(await key('innocent'), publicKeyBase64: pub);
      expect(unrelated.status, VipRedeemStatus.success,
          reason: 'control on the control — the CRL must revoke only what it '
              'names');
    });
  });
}
