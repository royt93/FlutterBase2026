// M6 (round-6 audit) — VIP entries normally live in secure storage
// (Keychain/Keystore). `setRaw()` writes the plaintext SharedPreferences copy
// only when the SECURE write fails (the T71 broken-Keystore path). That
// fallback's integrity is an unkeyed FNV-1a checksum whose salt is a literal in
// this package, so it is reproducible from the published pub.dev source: with
// root, an emulator, or a permissive backup path, a forged "VIP until 2099"
// entry planted there was accepted outright.
//
// The tell is that a fallback entry on a device whose secure storage WORKS has
// no legitimate way to exist. So the store probes, and the manager clamps
// rather than discards — a device whose Keystore was broken at grant time and
// healed later leaves a genuine entry in exactly that state, and the
// one-time-use ledger means that customer cannot redeem their code again.
//
// ROUND-6 QC caught the first version of this file mocking at the wrong layer:
// it subclassed VipEntriesStore and overrode `getRaw`, which is the very method
// that performs the probe — so production's probe was never executed and the
// tests would have stayed green with the whole mechanism deleted. That is the
// exact trap that let `tcfConsentString` pass four audit rounds while returning
// null on every real device. These tests now fake the LAYER BELOW — the
// FlutterSecureStorage the store talks to — and drive the real `getRaw`.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An in-memory secure store. With [broken] it throws on every call, which is
/// what a device with an unusable Keystore looks like from Dart.
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage({this.broken = false, this.failReadOfKey});
  final bool broken;

  /// Fails `read` for exactly this key while every other operation works —
  /// a transient read error, which is a different thing from an unusable
  /// Keystore and must not be treated as one.
  final String? failReadOfKey;
  final Map<String, String> _data = {};

  /// Proves the probe actually ran rather than being short-circuited.
  int writes = 0;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    if (broken) throw PlatformExceptionStub();
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (broken) throw PlatformExceptionStub();
    if (failReadOfKey != null && key == failReadOfKey) {
      throw PlatformExceptionStub();
    }
    return _data[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (broken) throw PlatformExceptionStub();
    _data.remove(key);
  }
}

class PlatformExceptionStub implements Exception {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
  });

  /// Plants a forged fallback entry the way an attacker with root would: valid
  /// checksum (the formula is public), absurd expiry.
  Future<void> plantForgedFallback() async {
    // Written through the real writer so the checksum is whatever production
    // considers valid — no hand-rolled copy of the algorithm here.
    await prefs.setVipEntriesFallbackRaw('[{"key":"FORGED",'
        '"expiresAt":"2099-01-01T00:00:00.000Z",'
        '"grantedAt":"2026-01-01T00:00:00.000Z"}]');
  }

  test('a fallback grant is clamped when secure storage is healthy', () async {
    final secure = _FakeSecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);
    await plantForgedFallback();

    final mgr = VipManager(prefs, vipEntriesStore: store);
    addTearDown(mgr.dispose);
    await mgr.load();

    expect(secure.writes, greaterThan(0),
        reason: 'the probe must actually have run — if this is 0 the test is '
            'not exercising production, which is how the first version of '
            'this file went wrong');
    expect(store.lastReadWasUntrustedFallback, isTrue);

    expect(mgr.isActive, isTrue,
        reason: 'not discarded — the entry may be genuine from a device whose '
            'Keystore was broken and has since healed, and the one-time-use '
            'ledger means that customer cannot re-redeem');
    final remaining = mgr.expiresAt!.difference(DateTime.now());
    expect(remaining.inHours, lessThanOrEqualTo(24),
        reason: 'a forged "VIP until 2099" must be worth a day, not forever');
  });

  test('a fallback grant is honoured in full when secure storage is broken',
      () async {
    final store =
        VipEntriesStore(prefs, secureStorage: _FakeSecureStorage(broken: true));
    await plantForgedFallback();

    final mgr = VipManager(prefs, vipEntriesStore: store);
    addTearDown(mgr.dispose);
    await mgr.load();

    expect(store.lastReadWasUntrustedFallback, isFalse,
        reason: 'a broken Keystore is exactly the case the fallback exists for');
    expect(mgr.isActive, isTrue);
    expect(mgr.expiresAt!.year, 2099,
        reason: 'clamping here would punish exactly the paying customers the '
            'fallback was added to rescue');
  });

  // Round-6 codex QC — `_readSecure()` returned null both for "no entry" and
  // for "the read threw". A transient read failure therefore looked exactly
  // like an empty store, the probe right after it succeeded, and a GENUINE
  // grant got clamped to 24h. The fake above fails one operation rather than
  // all of them, which is what the earlier `broken: true` fake could not
  // express.
  test('a transient read error is not mistaken for a planted fallback',
      () async {
    final secure = _FakeSecureStorage(failReadOfKey: 'ad_sdk_vip_entries_v1');
    final store = VipEntriesStore(prefs, secureStorage: secure);
    await plantForgedFallback();

    final mgr = VipManager(prefs, vipEntriesStore: store);
    addTearDown(mgr.dispose);
    await mgr.load();

    expect(store.lastReadWasUntrustedFallback, isFalse,
        reason: 'the entries read FAILED — that says nothing about whether the '
            'fallback was planted, and a healthy probe afterwards must not be '
            'read as proof that it was');
    expect(mgr.expiresAt!.year, 2099,
        reason: 'clamping on a transient read blip would quietly cut a paying '
            "customer's VIP");
  });

  // Round-6 final QC, found independently by BOTH reviewers — the clamp only
  // ever ran in memory. Every launch re-read the untouched "VIP until 2099"
  // line from the fallback and clamped it to now+24h again, so a forged entry
  // was a rolling 24h grant, renewed forever: M6 blocked nothing.
  //
  // The two tests above stayed green because each calls `load()` ONCE. Nothing
  // opened the app a second time — the state that mattered.
  test('the clamp is written down, not just applied in memory', () async {
    final secure = _FakeSecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);
    await plantForgedFallback();

    final mgr = VipManager(prefs, vipEntriesStore: store);
    addTearDown(mgr.dispose);
    await mgr.load();

    // The observable that matters is durability, not the in-memory value:
    // comparing two expiries inside one test run cannot see this bug, because
    // both are now+24h and `now` barely moves. Ask instead whether the clamped
    // list reached storage at all.
    final persisted = await store.getRaw();
    expect(persisted, isNotNull);
    expect(persisted!.contains('2099'), isFalse,
        reason: 'the forged 2099 expiry is still what storage holds, so every '
            'later launch re-reads it and clamps again — a rolling 24h grant, '
            'renewed forever, and M6 blocks nothing');
  });
}
