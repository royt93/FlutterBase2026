// M6 (round-6 audit) — VIP entries normally live in secure storage
// (Keychain/Keystore). `setRaw()` falls back to a plaintext SharedPreferences
// copy only when the SECURE write fails (the T71 broken-Keystore path). That
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

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves a planted fallback value, with a switchable "is the Keystore OK"
/// answer so both branches can be driven.
class _PlantedFallbackStore extends VipEntriesStore {
  _PlantedFallbackStore(super.prefs, {required this.secureWorks});
  final bool secureWorks;
  String? planted;

  @override
  Future<String?> getRaw() async {
    lastReadWasUntrustedFallback = secureWorks && planted != null;
    return planted;
  }

  @override
  Future<void> setRaw(String json) async => planted = json;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
  });

  String forgedEntries() => '[{"key":"FORGED",'
      '"expiresAt":"2099-01-01T00:00:00.000Z",'
      '"grantedAt":"2026-01-01T00:00:00.000Z"}]';

  test('a fallback grant is clamped when secure storage is healthy', () async {
    final store = _PlantedFallbackStore(prefs, secureWorks: true)
      ..planted = forgedEntries();
    final mgr = VipManager(prefs, vipEntriesStore: store);
    addTearDown(mgr.dispose);

    await mgr.load();

    expect(mgr.isActive, isTrue,
        reason: 'not discarded — the entry may be a genuine grant from a '
            'device whose Keystore was broken and has since healed, and the '
            'one-time-use ledger means that customer cannot re-redeem');
    final remaining = mgr.expiresAt!.difference(DateTime.now());
    expect(remaining.inHours, lessThanOrEqualTo(24),
        reason: 'a forged "VIP until 2099" must be worth a day, not forever');
  });

  test('a fallback grant is honoured in full when secure storage is broken',
      () async {
    final store = _PlantedFallbackStore(prefs, secureWorks: false)
      ..planted = forgedEntries();
    final mgr = VipManager(prefs, vipEntriesStore: store);
    addTearDown(mgr.dispose);

    await mgr.load();

    expect(mgr.isActive, isTrue);
    expect(mgr.expiresAt!.year, 2099,
        reason: 'the fallback exists FOR these devices — clamping here would '
            'punish exactly the paying customers it was added to rescue');
  });
}
