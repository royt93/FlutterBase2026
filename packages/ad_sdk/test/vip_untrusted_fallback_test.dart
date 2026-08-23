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
  _FakeSecureStorage({this.broken = false});
  final bool broken;
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
}
