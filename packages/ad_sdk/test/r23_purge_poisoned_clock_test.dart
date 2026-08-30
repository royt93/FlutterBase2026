// Round-23 QC (reviewer C, BLOCKER) — a poisoned clock mark must be able to
// SUPPRESS a paid VIP entry, never to DESTROY it.
//
// `_effectiveNow()` returns the high-water mark whenever the mark is ahead of
// the device clock, and the mark is never lowered — that is what makes the
// rollback defence work. It also means the mark can be permanently ahead of
// real time, and it takes no attacker to get there: a phone whose battery went
// flat boots with a wrong date, the user opens the app once, and that date is
// committed to the mark. NTP corrects the clock a minute later.
//
// From the next launch on, `_purgeExpired()` compared every entry against a
// clock years in the future, decided they were all over, `removeWhere`d them
// and `_save()`d the empty list. The customer's paid VIP was gone from disk —
// and unrecoverable: this SDK has no backend, and the key id is already burned
// in the one-time-use ledger, so re-entering the key they paid for answers
// "already used".
//
// The rule the codebase already states for the not-yet-started half —
// *suppress, never delete* — now covers the expiry half too: a row goes only
// when the mark-clamped clock AND the raw device clock both say it is over.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart' show VipEntry;
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
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

/// `_purgeExpired` writes back through `unawaited(_save())`, so an assertion
/// made on the very next microtask can read the store before the write lands.
/// Every disk assertion below goes through this first, otherwise the test is a
/// coin flip rather than a proof.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
    await VipManager(prefs, vipEntriesStore: store).revokeAll();
    await prefs
        .setVipMaxObservedClockMs(DateTime.now().millisecondsSinceEpoch);
  });

  test(
      'a mark poisoned AFTER the grant suppresses the entry but leaves it on '
      'disk', () async {
    // 1. The customer pays while the device clock is correct.
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    await mgr.addVip(key: 'PAID-90D', duration: const Duration(days: 90));
    expect(mgr.isActive, isTrue, reason: 'sanity — the grant starts live');

    // 2. Flat battery: the phone boots on a date years ahead, the user opens
    //    the app once, and that date is committed to the high-water mark.
    await prefs.setVipMaxObservedClockMs(
        DateTime.now().add(const Duration(days: 800)).millisecondsSinceEpoch);

    // 3. NTP corrects the clock; the app is launched again.
    final poisoned = VipManager(prefs, vipEntriesStore: store);
    await poisoned.load();
    addTearDown(poisoned.dispose);
    await _settle();

    expect(poisoned.isActive, isFalse,
        reason: 'suppression against the mark is the documented, deliberate '
            'cost of the rollback defence — that part is unchanged');
    expect(await store.getRaw(), contains('PAID-90D'),
        reason: 'THE finding: the paid row must still exist on disk. There is '
            'no backend to restore it from and the key id is already burned.');
  });

  test('and clearing the poisoned mark brings the entitlement back', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    await mgr.addVip(key: 'PAID-90D', duration: const Duration(days: 90));

    await prefs.setVipMaxObservedClockMs(
        DateTime.now().add(const Duration(days: 800)).millisecondsSinceEpoch);
    final poisoned = VipManager(prefs, vipEntriesStore: store);
    await poisoned.load();
    addTearDown(poisoned.dispose);
    expect(poisoned.isActive, isFalse);

    // Support resets the mark (or a fresh install does). Because the row
    // survived, the customer gets the rest of what they paid for. Under the
    // old purge this expectation was unreachable — there was nothing left.
    await prefs
        .setVipMaxObservedClockMs(DateTime.now().millisecondsSinceEpoch);
    final recovered = VipManager(prefs, vipEntriesStore: store);
    await recovered.load();
    addTearDown(recovered.dispose);

    expect(recovered.isActive, isTrue);
    expect(recovered.expiresAt, isNotNull);
    expect(
        recovered.expiresAt!.difference(DateTime.now()).inDays,
        greaterThan(80),
        reason: 'the remaining window is intact, not restarted');
  });

  test(
      'CONTROL — an entry that is genuinely over on BOTH clocks is still '
      'purged', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    await mgr.addVip(key: 'SHORT', duration: const Duration(milliseconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final reloaded = VipManager(prefs, vipEntriesStore: store);
    await reloaded.load();
    addTearDown(reloaded.dispose);
    await _settle();

    expect(reloaded.isActive, isFalse);
    expect(await store.getRaw() ?? '', isNot(contains('SHORT')),
        reason: 'the fix narrows WHEN a row is deleted; it does not stop the '
            'store growing without bound');
  });

  test(
      'CONTROL — a rolled-back clock still cannot resurrect a genuinely '
      'expired entry', () async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    await mgr.addVip(key: 'ROLLBACK', duration: const Duration(days: 10));

    // Observed at now+30d — i.e. the grant has already run out — and then the
    // clock is wound back inside the window. Keeping the row on disk must not
    // hand the entitlement back.
    await prefs.setVipMaxObservedClockMs(
        DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch);

    final reloaded = VipManager(prefs, vipEntriesStore: store);
    await reloaded.load();
    addTearDown(reloaded.dispose);

    expect(reloaded.isActive, isFalse,
        reason: 'isActive still reads the mark-clamped clock — purge is '
            'housekeeping, never the security control');
  });

  // ── Round-24 QC (reviewer A, MAJOR) ─────────────────────────────────────
  //
  // The round-23 fix asked `!isActiveAt(now) && !isActiveAt(real)`, which reads
  // as "both clocks say it is not active". That is not the same question as
  // "both clocks say it is over": `isActiveAt` is start-aware and is ALSO false
  // while the clock reads before `grantedAt`. So a grant stamped in the future
  // — taken while the device clock was running ahead — was still deleted
  // outright once the mark was gone. Same bug class as V1, one branch over.

  test(
      'a grant stamped in the future is NOT deleted when the clock mark is '
      'missing entirely', () async {
    // The reachable shape, no attacker: the row is Keychain-backed and survives
    // an iOS reinstall; the mark lives in SharedPreferences and does not.
    final granted = DateTime.now().add(const Duration(days: 30));
    final entry = VipEntry(
      key: 'PAID-FUTURE',
      grantedAt: granted,
      expiresAt: granted.add(const Duration(days: 90)),
    );
    await store.setRaw(jsonEncode([entry.toJson()]));
    await prefs.setVipMaxObservedClockMs(0); // no usable mark

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    await _settle();

    expect(await store.getRaw(), contains('PAID-FUTURE'),
        reason: 'THE round-24 finding — the window has not STARTED, let alone '
            'ended; deleting it destroys a paid, already-burned key');
    expect(mgr.isActive, isFalse,
        reason: 'and it is still correctly suppressed until its window opens');
  });

  test('and it keeps surviving every subsequent launch, not just the first',
      () async {
    // A row that survives one purge and dies on the next is no better than a
    // row that dies immediately — it just takes one more app start.
    final granted = DateTime.now().add(const Duration(days: 30));
    final entry = VipEntry(
      key: 'PAID-FUTURE',
      grantedAt: granted,
      expiresAt: granted.add(const Duration(days: 90)),
    );
    await store.setRaw(jsonEncode([entry.toJson()]));
    await prefs.setVipMaxObservedClockMs(0);

    for (var launch = 0; launch < 3; launch++) {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      await _settle();
      mgr.dispose();
      expect(await store.getRaw(), contains('PAID-FUTURE'),
          reason: 'still there after launch ${launch + 1}');
    }
  });

  test(
      'CONTROL — a row whose window has genuinely ENDED under both clocks is '
      'still removed', () async {
    final entry = VipEntry(
      key: 'REALLY-OVER',
      grantedAt: DateTime.now().subtract(const Duration(days: 40)),
      expiresAt: DateTime.now().subtract(const Duration(days: 10)),
    );
    await store.setRaw(jsonEncode([entry.toJson()]));
    await prefs
        .setVipMaxObservedClockMs(DateTime.now().millisecondsSinceEpoch);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    await _settle();

    expect(await store.getRaw() ?? '[]', isNot(contains('REALLY-OVER')),
        reason: 'housekeeping must still do its job, or the record grows '
            'without bound on a long-lived install');
  });
}
