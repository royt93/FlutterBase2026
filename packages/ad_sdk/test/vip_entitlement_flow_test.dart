// Integration-style test for the VIP entitlement subsystem.
//
// Unlike the pure-unit tests (vip_entry_test), this wires REAL collaborators
// together — VipManager + AdPreferences + SharedPreferences persistence + the
// reactive `activeListenable`/`activeStream` — and exercises the end-to-end
// entitlement lifecycle the host app depends on:
//
//   redeem → active (reactive notify) → persist → reload from "disk" →
//   conflict (latest-expiry-wins) → expire/purge on load → revoke.
//
// It runs under `flutter test` (no device needed) because every dependency is
// real except the SharedPreferences backing store, which is mocked in-memory.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_entry.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
    // Shared singleton store → wipe persisted entries for a clean slate.
    await VipManager(prefs, vipEntriesStore: store).revokeAll();
  });

  test('redeem activates entitlement and fires the reactive notifier',
      () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    expect(mgr.isActive, isFalse);

    final transitions = <bool>[];
    mgr.activeListenable.addListener(() => transitions.add(mgr.isActive));

    await mgr.addVip(key: 'KEY_30D', duration: const Duration(days: 30));

    expect(mgr.isActive, isTrue);
    expect(transitions, [true],
        reason: 'notifier fires exactly once false→true');
    addTearDown(() => mgr.dispose());
  });

  test('entitlement survives a reload from persistence', () async {
    final writer = VipManager(prefs, vipEntriesStore: store);
    await writer.load();
    await writer.addVip(key: 'KEY_PERSIST', duration: const Duration(hours: 1));
    expect(writer.isActive, isTrue);

    // Fresh manager reading the SAME backing store = app relaunch.
    final reader = VipManager(prefs, vipEntriesStore: store);
    await reader.load();
    expect(reader.isActive, isTrue,
        reason: 'persisted entry must restore active state across instances');
  });

  test('latest-expiry-wins when the same key is redeemed twice', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();

    await mgr.addVip(key: 'DUP', duration: const Duration(hours: 1));
    await mgr.addVip(key: 'DUP', duration: const Duration(hours: 5)); // later
    await mgr.addVip(
        key: 'DUP', duration: const Duration(minutes: 10)); // earlier

    // Reload to inspect what actually persisted.
    final reader = VipManager(prefs, vipEntriesStore: store);
    await reader.load();
    final expiry = reader.expiresAt;
    expect(expiry, isNotNull);
    final remaining = expiry!.difference(DateTime.now());
    expect(remaining.inMinutes, greaterThan(60),
        reason: 'the 5h grant must win over both the 1h and 10m grants');
    expect(remaining.inMinutes, lessThan(5 * 60 + 1));
  });

  test('expired entries are purged on load and do not grant access', () async {
    // Inject a stale entry straight into the backing store (past expiry).
    final expired = VipEntry(
      key: 'STALE',
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      grantedAt: DateTime.now().subtract(const Duration(days: 31)),
    );
    final fresh = VipEntry(
      key: 'LIVE',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      grantedAt: DateTime.now(),
    );
    await store.setRaw(VipEntry.encodeList([expired, fresh]));

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();

    // Still active because of LIVE, but STALE must be gone after purge.
    expect(mgr.isActive, isTrue);
    final reader = VipManager(prefs, vipEntriesStore: store);
    await reader.load();
    expect(reader.isActive, isTrue);
    // Revoking LIVE should leave nothing active (STALE was already purged).
    await reader.revokeVip('LIVE');
    expect(reader.isActive, isFalse);
  });

  test('revokeAll clears entitlement and notifies', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    await mgr.addVip(key: 'KEY_A', duration: const Duration(days: 1));
    expect(mgr.isActive, isTrue);

    await mgr.revokeAll();
    expect(mgr.isActive, isFalse);

    final reader = VipManager(prefs, vipEntriesStore: store);
    await reader.load();
    expect(reader.isActive, isFalse, reason: 'revokeAll must persist the wipe');
  });

  test(
      'mid-session expiry timer flips isActive to false without a reload '
      '(covers _scheduleNextExpiry/_handleExpiry)', () async {
    // NOTE: real (not fakeAsync) delay — VipManager/VipEntry read wall-clock
    // DateTime.now() directly (no injected clock), so fakeAsync's virtual
    // clock would advance the Timer callback instantly while DateTime.now()
    // stays real, and the entry would not actually look expired yet.
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    await mgr.addVip(key: 'SOON', duration: const Duration(milliseconds: 200));
    expect(mgr.isActive, isTrue);

    final transitions = <bool>[];
    mgr.activeListenable.addListener(() => transitions.add(mgr.isActive));

    // Wait past the entry's expiry without calling load()/addVip()/
    // revokeVip() again — only the internal Timer should flip state.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(mgr.isActive, isFalse,
        reason: 'the one-shot expiry Timer must purge + refresh on its own');
    expect(transitions, [false],
        reason: 'notifier fires exactly once true→false on timer expiry');

    mgr.dispose();
  });

  test('legacy 1.x GAID migration: matches vs. non-matches, then never rescans',
      () async {
    // Simulate the pre-2.x on-disk shape: a flat list of VIP-eligible GAIDs,
    // no 2.x entries yet, migration flag unset.
    await prefs.saveGAIDList(['device-a-gaid', 'device-b-gaid']);

    // This device's GAID is NOT in the legacy list — must not be promoted,
    // even though the legacy list itself contains other devices' GAIDs.
    final theirs = VipManager(prefs, vipEntriesStore: store);
    await theirs.load(currentDeviceGaid: 'device-c-not-in-list');
    expect(theirs.isActive, isFalse,
        reason: 'non-matching GAID must not be migrated to an entry');
    expect(prefs.isVipMigrated(), isTrue,
        reason: 'migration flag is set even when nothing matched');

    // A second load() must be a no-op rescan-wise (isVipMigrated()==true
    // skip path) — reloading with a NOW-matching GAID must still not
    // retroactively promote, because migration only ever runs once.
    final again = VipManager(prefs, vipEntriesStore: store);
    await again.load(currentDeviceGaid: 'device-a-gaid');
    expect(again.isActive, isFalse,
        reason: 'migration flag already set — load() must not rescan');

    // Reset to a genuinely fresh (unmigrated) store to exercise the
    // matching-GAID branch itself: promotion to a far-future LEGACY_ entry.
    await prefs.clearAllData();
    await prefs.saveGAIDList(['device-a-gaid', 'device-b-gaid']);
    // Fresh install after clearAllData() → a brand-new store too, not the
    // one still holding the (now-cleared) prior entries.
    final freshStore = _FakeVipEntriesStore(prefs);
    final mine = VipManager(prefs, vipEntriesStore: freshStore);
    await mine.load(currentDeviceGaid: 'device-a-gaid');

    expect(mine.isActive, isTrue,
        reason: 'this device\'s GAID was in the legacy list');
    expect(prefs.isVipMigrated(), isTrue);
    expect(mine.entries.single.key, 'LEGACY_DEVICE-A-GAID');
    expect(mine.entries.single.expiresAt.year, 2099,
        reason: 'legacy migration grants an effectively-permanent entry');
  });
}
