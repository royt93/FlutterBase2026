// Unit + integration-style tests for VIP time STACKING (cộng dồn) — the
// `stack: true` path on [VipManager.addVip] added for the host's "redeem key"
// and "watch ad → +N days" flows.
//
// Contract under test:
//   - stack on a brand-new key            → behaves like a fresh add (now + d)
//   - stack on an ACTIVE existing key      → old.expiresAt + d  (accumulate)
//   - stack repeatedly                     → windows add up
//   - stack vs default (latest-wins)       → stack is strictly longer
//   - stack resets grantedAt to "now"      → progress bar restarts each top-up
//   - stacking persists across a reload    → survives an app relaunch
//   - the watch-ad fixed-key pattern        → one entry accumulates, no clutter
//
// Backing store is the in-memory SharedPreferences mock, every other
// collaborator is real (matches vip_entitlement_flow_test).

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
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

  // Helper: remaining time of the single active entry, in minutes.
  int remainingMinutes(VipManager mgr) {
    final expiry = mgr.expiresAt;
    expect(expiry, isNotNull);
    return expiry!.difference(DateTime.now()).inMinutes;
  }

  test('stack on a brand-new key behaves like a normal fresh add', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    final entry = await mgr.addVip(
      key: 'NEW',
      duration: const Duration(hours: 2),
      stack: true,
    );

    expect(mgr.isActive, isTrue);
    expect(entry.key, 'NEW');
    // ~120 min (allow a minute of scheduling slack).
    expect(remainingMinutes(mgr), inInclusiveRange(119, 120));
  });

  test('stack on an ACTIVE key accumulates: old expiry + new duration',
      () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'DUP', duration: const Duration(hours: 1));
    final stacked = await mgr.addVip(
      key: 'DUP',
      duration: const Duration(hours: 2),
      stack: true,
    );

    // 1h existing + 2h added ≈ 3h total — NOT a 2h reset.
    expect(stacked.key, 'DUP');
    expect(remainingMinutes(mgr), inInclusiveRange(179, 180),
        reason: '1h window + 2h stacked must total ~3h');
  });

  test('stacking repeatedly keeps adding up', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'R', duration: const Duration(days: 3), stack: true);
    await mgr.addVip(key: 'R', duration: const Duration(days: 3), stack: true);
    await mgr.addVip(key: 'R', duration: const Duration(days: 3), stack: true);

    final expiry = mgr.expiresAt!;
    final remainingHours = expiry.difference(DateTime.now()).inHours;
    // 3 × 3 days = 9 days = 216h (allow a small slack).
    expect(remainingHours, inInclusiveRange(215, 216));
    // Still exactly ONE entry — no clutter.
    expect(mgr.entries.length, 1);
  });

  test('stack produces a strictly longer window than the default (latest-wins)',
      () async {
    // Default branch: re-adding the SAME duration just keeps ~1h.
    final plain = VipManager(prefs, vipEntriesStore: store);
    await plain.load();
    await plain.addVip(key: 'A', duration: const Duration(hours: 1));
    await plain.addVip(
        key: 'A', duration: const Duration(hours: 1)); // no stack
    final plainMin = remainingMinutes(plain);
    plain.dispose();

    // Fresh store for a genuinely clean slate — reusing `store` here would
    // still carry the "plain" scenario's persisted entry underneath.
    final freshStore = _FakeVipEntriesStore(prefs);
    await VipManager(prefs, vipEntriesStore: freshStore).revokeAll();

    // Stack branch: the second add piles on top.
    final stacked = VipManager(prefs, vipEntriesStore: freshStore);
    await stacked.load();
    await stacked.addVip(key: 'A', duration: const Duration(hours: 1));
    await stacked.addVip(
        key: 'A', duration: const Duration(hours: 1), stack: true);
    final stackedMin = remainingMinutes(stacked);
    stacked.dispose();

    expect(plainMin, inInclusiveRange(59, 60),
        reason: 'latest-wins keeps a single 1h window');
    expect(stackedMin, inInclusiveRange(119, 120),
        reason: 'stack accumulates to ~2h');
    expect(stackedMin, greaterThan(plainMin));
  });

  test('stacking resets grantedAt to ~now (progress bar restarts each top-up)',
      () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'G', duration: const Duration(hours: 1));
    final before = DateTime.now();
    final stacked = await mgr.addVip(
        key: 'G', duration: const Duration(hours: 1), stack: true);
    final after = DateTime.now();

    expect(
      stacked.grantedAt.isAfter(before.subtract(const Duration(seconds: 1))),
      isTrue,
    );
    expect(
      stacked.grantedAt.isBefore(after.add(const Duration(seconds: 1))),
      isTrue,
    );
  });

  test('stacked total survives a reload from persistence', () async {
    final writer = VipManager(prefs, vipEntriesStore: store);
    await writer.load();
    await writer.addVip(key: 'P', duration: const Duration(hours: 2));
    await writer.addVip(
        key: 'P', duration: const Duration(hours: 2), stack: true);
    writer.dispose();

    // Fresh manager reading the same store = app relaunch.
    final reader = VipManager(prefs, vipEntriesStore: store);
    await reader.load();
    addTearDown(reader.dispose);

    expect(reader.isActive, isTrue);
    expect(reader.entries.length, 1);
    expect(remainingMinutes(reader), inInclusiveRange(239, 240),
        reason: '2h + 2h stacked must persist as ~4h');
  });

  test('stacking flips active state and fires the reactive notifier once',
      () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    expect(mgr.isActive, isFalse);

    final transitions = <bool>[];
    mgr.activeListenable.addListener(() => transitions.add(mgr.isActive));

    await mgr.addVip(key: 'N', duration: const Duration(hours: 1), stack: true);
    await mgr.addVip(key: 'N', duration: const Duration(hours: 1), stack: true);

    expect(mgr.isActive, isTrue);
    // false→true exactly once; the second stack does not re-toggle.
    expect(transitions, [true]);
  });

  test(
      'GLOBAL stacking: a different key extends from the latest expiry across '
      'all entries', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    // Window from source A (e.g. watch-ad), then a DIFFERENT key (e.g. a code).
    await mgr.addVip(
        key: 'WATCH', duration: const Duration(days: 6), stack: true);
    await mgr.addVip(
        key: 'CODE30', duration: const Duration(days: 30), stack: true);

    final remainingDays = mgr.expiresAt!.difference(DateTime.now()).inDays;
    expect(remainingDays, inInclusiveRange(35, 36),
        reason: '6d + 30d across different keys must total ~36d');
    expect(mgr.entries.length, 2,
        reason: 'both grants kept as separate entries');
  });

  test(
      'trial + redeem: redeeming a paid code while the first-install trial '
      'is still active ADDS onto it rather than overwriting/shortening it',
      () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    // Mirrors AdManager's first-install grant: fixed key (matches
    // AdConfig.firstInstallVipKey's default of '__FIRST_INSTALL__').
    const trialKey = '__FIRST_INSTALL__';
    await mgr.addVip(
      key: trialKey,
      duration: const Duration(days: 1),
      stack: true,
    );
    final trialOnly = mgr.expiresAt!;

    // User redeems a signed/paid code under a DIFFERENT key while the
    // trial entry is still active (mirrors redeemSignedKey's stack: true).
    await mgr.addVip(
      key: 'SIGNED_ABC123',
      duration: const Duration(days: 30),
      stack: true,
    );

    // The trial entry must still exist, untouched, alongside the new one —
    // not replaced or shortened.
    final trialEntry = mgr.entries.singleWhere((e) => e.key == trialKey);
    expect(trialEntry.expiresAt, trialOnly,
        reason: 'trial entry itself must be untouched by the redeem');
    expect(mgr.entries.length, 2,
        reason: 'trial and redeemed code remain distinguishable entries');

    // Total window must be the SUM (trial + redeemed), not a replacement.
    final remainingDays = mgr.expiresAt!.difference(DateTime.now()).inDays;
    expect(remainingDays, inInclusiveRange(30, 31),
        reason: '1d trial + 30d redeemed code must total ~31d, not just 30d');
  });

  test('GLOBAL stacking is order-independent (code first, then watch-ad)',
      () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(
        key: 'CODE30', duration: const Duration(days: 30), stack: true);
    await mgr.addVip(
        key: 'WATCH', duration: const Duration(days: 3), stack: true);

    final remainingDays = mgr.expiresAt!.difference(DateTime.now()).inDays;
    expect(remainingDays, inInclusiveRange(32, 33), reason: '30d + 3d = ~33d');
  });

  test('GLOBAL stacking across different keys still respects the cap',
      () async {
    final mgr = VipManager(prefs,
        maxStackDuration: const Duration(days: 30), vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'A', duration: const Duration(days: 20), stack: true);
    // 20d + 20d = 40d across keys → clamped to the 30-day cap.
    await mgr.addVip(key: 'B', duration: const Duration(days: 20), stack: true);

    final remainingDays = mgr.expiresAt!.difference(DateTime.now()).inDays;
    expect(remainingDays, inInclusiveRange(29, 30),
        reason: 'total clamped to 30d');
  });

  test('stacking is clamped to maxStackDuration when the cap is set', () async {
    final mgr = VipManager(prefs,
        maxStackDuration: const Duration(days: 7), vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'C', duration: const Duration(days: 5), stack: true);
    // 5d + 5d = 10d, but the 7-day cap clamps it.
    await mgr.addVip(key: 'C', duration: const Duration(days: 5), stack: true);

    final remainingHours = mgr.expiresAt!.difference(DateTime.now()).inHours;
    expect(remainingHours, inInclusiveRange(167, 168),
        reason: 'total window clamped to the 7-day cap');
  });

  test('no cap (null) → stacking is unbounded', () async {
    final mgr =
        VipManager(prefs, vipEntriesStore: store); // maxStackDuration null
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'U', duration: const Duration(days: 5), stack: true);
    await mgr.addVip(key: 'U', duration: const Duration(days: 5), stack: true);

    final remainingHours = mgr.expiresAt!.difference(DateTime.now()).inHours;
    expect(remainingHours, inInclusiveRange(239, 240),
        reason: 'no cap → full 10-day accumulation');
  });

  test('watch-ad fixed-key pattern: repeats accumulate into ONE entry',
      () async {
    // Mirrors `_onWatchAdForVip`: always the same key, always stack, +3d each.
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    const rewardKey = 'REWARDED_VIP';
    await mgr.addVip(
        key: rewardKey, duration: const Duration(days: 3), stack: true);
    await mgr.addVip(
        key: rewardKey, duration: const Duration(days: 3), stack: true);

    expect(mgr.entries.length, 1, reason: 'one fixed key → one entry');
    final remainingHours = mgr.expiresAt!.difference(DateTime.now()).inHours;
    expect(remainingHours, inInclusiveRange(143, 144),
        reason: '2 × 3 days = 6 days ≈ 144h');
  });
}
