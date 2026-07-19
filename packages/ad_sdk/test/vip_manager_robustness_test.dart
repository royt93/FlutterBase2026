// T19 — VIP robustness: non-positive duration rejection, eager expired-entry
// purge on load/redeem, and the stack-cap-vs-non-stacking-uncapped contract.
//
// Backing store is the in-memory SharedPreferences mock, same pattern as
// vip_entitlement_flow_test.dart / vip_manager_stacking_test.dart.

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

  group('non-positive duration rejected', () {
    test('addVip with Duration.zero fails the debug assert', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      expect(
        () => mgr.addVip(key: 'ZERO', duration: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
    });

    test('addVip with a negative duration fails the debug assert', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      expect(
        () => mgr.addVip(key: 'NEG', duration: const Duration(hours: -1)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a rejected duration never creates or activates an entry', () async {
      // Assertions are disabled in some release-style harnesses; exercise the
      // guarded branch directly by tolerating either outcome and asserting
      // the invariant that matters: no dead/inverted entry survives.
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      try {
        await mgr.addVip(key: 'BAD', duration: Duration.zero);
      } catch (_) {
        // Debug mode: assert throws before mutating state — expected.
      }
      expect(mgr.isActive, isFalse);
      expect(mgr.entries.any((e) => e.key == 'BAD'), isFalse);
    });
  });

  group('eager purge on load/redeem', () {
    test(
        'load() shrinks the persisted store, not just the in-memory active '
        'flag', () async {
      final expired = VipEntry(
        key: 'STALE',
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        grantedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      await store.setRaw(VipEntry.encodeList([expired]));

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      expect(mgr.entries, isEmpty);
      // load()'s purge-triggered save is fire-and-forget (unawaited) in
      // production, so give the queued write a turn to land before reading.
      await Future<void>.delayed(Duration.zero);
      // The raw persisted JSON itself must be shrunk, not just the in-memory
      // list — otherwise stale rows keep accumulating in the store.
      final persisted = VipEntry.decodeList(await store.getRaw());
      expect(persisted, isEmpty);
    });

    test(
        'addVip purges an entry that expired AFTER load (not just at load '
        'time) before adding a new one', () async {
      // Was active at load() time, so load()'s purge doesn't touch it — it
      // only crosses into "expired" a moment later, mid-session. Without an
      // eager purge in addVip itself this would sit in persistence until the
      // next expiry-timer fire or app relaunch.
      final soonToExpire = VipEntry(
        key: 'SOON_STALE',
        expiresAt: DateTime.now().add(const Duration(milliseconds: 5)),
        grantedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      await store.setRaw(VipEntry.encodeList([soonToExpire]));

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);
      expect(mgr.entries.length, 1, reason: 'still active at load() time');

      // Let it actually cross into expired before the next mutation.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await mgr.addVip(key: 'FRESH', duration: const Duration(hours: 1));

      expect(mgr.entries.length, 1);
      expect(mgr.entries.single.key, 'FRESH');
      final persisted = VipEntry.decodeList(await store.getRaw());
      expect(persisted.any((e) => e.key == 'SOON_STALE'), isFalse);
    });

    test('redeemSignedKey-style add (via addVip) purges expired entries too',
        () async {
      // redeemSignedKey forwards to addVip, so exercising addVip covers the
      // redeem path without needing a signed key fixture here.
      final expired = VipEntry(
        key: 'OLD',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        grantedAt: DateTime.now().subtract(const Duration(days: 2)),
      );
      await store.setRaw(VipEntry.encodeList([expired]));

      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.addVip(
          key: 'REDEEMED', duration: const Duration(days: 1), stack: true);

      final persisted = VipEntry.decodeList(await store.getRaw());
      expect(persisted.length, 1);
      expect(persisted.single.key, 'REDEEMED');
    });
  });

  group('maxStackDuration cap scope', () {
    test('stacking clamps at the cap', () async {
      final mgr = VipManager(prefs,
          maxStackDuration: const Duration(days: 10), vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.addVip(
          key: 'S', duration: const Duration(days: 8), stack: true);
      await mgr.addVip(
          key: 'S', duration: const Duration(days: 8), stack: true);
      // 8 + 8 = 16d, clamped to 10d.
      final remainingDays = mgr.expiresAt!.difference(DateTime.now()).inDays;
      expect(remainingDays, inInclusiveRange(9, 10));
    });

    test(
        'T49: non-stacking grants ARE ALSO capped by maxStackDuration, even '
        'when the requested duration is far beyond it', () async {
      final mgr = VipManager(prefs,
          maxStackDuration: const Duration(days: 10), vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      // Plain (default stack: false) grant, absolute duration way past cap.
      final entry =
          await mgr.addVip(key: 'PLAIN', duration: const Duration(days: 365));

      final remainingDays = entry.expiresAt.difference(DateTime.now()).inDays;
      expect(remainingDays, inInclusiveRange(9, 10),
          reason: 'non-stacking path must also respect maxStackDuration');
    });
  });

  group('VipEntry ISO8601 encoding preserves the exact instant', () {
    // NOTE on naming: [VipEntry.toJson] calls the plain `DateTime.toIso8601String()`
    // on whatever zone it was given — an explicitly-UTC DateTime encodes with
    // a `Z` suffix, a local DateTime (what VipManager actually stores, via
    // `DateTime.now()`) encodes with a zone-less local timestamp. Dart's
    // `DateTime.parse` round-trips either form correctly (it respects the
    // suffix), so persistence is instant-safe either way. This group locks in
    // that round-trip guarantee for both zones so a future change can't
    // silently break it.
    test('an explicitly-UTC entry round-trips through JSON with a Z suffix',
        () {
      final entry = VipEntry(
        key: 'UTC_CHECK',
        expiresAt: DateTime.utc(2026, 1, 1, 12, 30),
        grantedAt: DateTime.utc(2025, 12, 31, 12, 30),
      );
      final json = entry.toJson();
      expect(json['expiresAt'], endsWith('Z'));
      expect(json['grantedAt'], endsWith('Z'));

      final back = VipEntry.fromJson(json);
      expect(back.expiresAt.isUtc, isTrue);
      expect(back.expiresAt, entry.expiresAt);
      expect(back.grantedAt, entry.grantedAt);
    });

    test(
        'a real VipManager grant (local DateTime.now()) round-trips through '
        'persistence with the same absolute instant', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      final entry =
          await mgr.addVip(key: 'RT', duration: const Duration(hours: 3));

      final reader = VipManager(prefs, vipEntriesStore: store);
      await reader.load();
      addTearDown(reader.dispose);

      final reloaded = reader.entries.single;
      // Compare in UTC so the assertion holds regardless of which zone each
      // DateTime happens to carry — what matters is the same instant survived.
      expect(reloaded.expiresAt.toUtc(), entry.expiresAt.toUtc());
      expect(reloaded.grantedAt.toUtc(), entry.grantedAt.toUtc());
    });
  });
}
