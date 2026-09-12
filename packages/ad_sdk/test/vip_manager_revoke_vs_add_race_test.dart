// T176 — VIP security test: revokeAll() and addVip(stack: true) interleaved
// as genuinely concurrent operations (both started before either resolves,
// not called sequentially with an `await` in between), proving the shared
// `_entries` list and the `_save()` persistence queue never leave a revoked
// entry resurrected, nor a legitimately-added entry silently discarded.
//
// `_save()` (vip_manager.dart) is a STRICT queue: each call chains onto the
// previous one, and each queued write reads `_entries` at EXECUTION time
// (when its turn in the queue comes up), not at call time. That is the
// existing design this file verifies actually holds under interleaving —
// see the "Round-12 QC" comment on `_save()` for the reasoning it was built
// against (a stale snapshot landing last on disk).

import 'dart:async';

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory fake so this test doesn't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel.
///
/// codex review (round 1) — a plain instant fake (`setRaw` with no real
/// delay) cannot tell "the `_saveQueue` chain genuinely serializes writes"
/// apart from "there is no queue at all, but nothing ever took long enough
/// for two writes to reorder anyway". [holdNextWrite] lets a test force a
/// write to sit in flight on purpose, so a scenario where a queue-less
/// implementation WOULD let a later write overtake an earlier (held) one
/// is actually exercised, not just assumed safe by lucky timing.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? raw;
  bool holdNextWrite = false;
  final List<Completer<void>> _pendingGates = [];

  @override
  Future<String?> getRaw() async => raw;

  @override
  Future<void> setRaw(String json) async {
    if (holdNextWrite) {
      holdNextWrite = false;
      final gate = Completer<void>();
      _pendingGates.add(gate);
      await gate.future;
    }
    raw = json;
  }

  /// Lets the oldest still-held write (see [holdNextWrite]) actually land.
  void releaseNextWrite() {
    if (_pendingGates.isNotEmpty) _pendingGates.removeAt(0).complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late _FakeVipEntriesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    store = _FakeVipEntriesStore(prefs);
  });

  group('T176 — revokeAll() vs addVip(stack: true), genuinely interleaved',
      () {
    test(
        'addVip() started, then revokeAll() started before addVip() '
        'resolves — final state has NO active VIP (revoke wins, no '
        'resurrection), on reload from disk too', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      // Both started back-to-back, BEFORE either is awaited — this is what
      // makes it a genuine interleaving rather than two sequential calls.
      final addFuture =
          mgr.addVip(key: 'A', duration: const Duration(hours: 1), stack: true);
      final revokeFuture = mgr.revokeAll();
      await Future.wait([addFuture, revokeFuture]);

      expect(mgr.isActive, isFalse,
          reason: 'T176 — revokeAll() was issued after addVip(), so the '
              'grant it raced against must not survive in memory');

      // The crux of the security concern: does the PERSISTED store agree,
      // or did a stale write land last and resurrect the revoked grant on
      // the next app launch? Reload with a brand-new manager instance
      // backed by the SAME store.
      final reloaded = VipManager(prefs, vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.isActive, isFalse,
          reason: 'T176 — a fresh manager reading the same persisted store '
              'must not see the revoked grant resurrected');
    });

    test(
        'revokeAll() started, then addVip() started before revokeAll() '
        'resolves — final state HAS the new grant active (add legitimately '
        'came after revoke), on reload from disk too', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);
      await mgr.addVip(key: 'PRIOR', duration: const Duration(hours: 1));

      final revokeFuture = mgr.revokeAll();
      final addFuture = mgr.addVip(
          key: 'B', duration: const Duration(hours: 2), stack: true);
      await Future.wait([revokeFuture, addFuture]);

      expect(mgr.isActive, isTrue,
          reason: 'T176 — addVip() was issued after revokeAll(), so this '
              'grant must survive — a legitimate concurrent purchase must '
              'not be silently discarded by a revoke that logically '
              'preceded it');

      final reloaded = VipManager(prefs, vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.isActive, isTrue,
          reason: 'T176 — the persisted store must agree: the new grant, '
              'not the prior (correctly revoked) one, survives a reload');
    });

    test(
        'a slow held write (revoke) cannot be overtaken by a later-queued '
        'write (add) — proves the _saveQueue chain, not just lucky timing, '
        'is what keeps writes ordered', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      // Hold revokeAll()'s write in flight artificially — simulates a slow
      // real platform round-trip (flutter_secure_storage), which a plain
      // instant fake can never exercise.
      store.holdNextWrite = true;
      final revokeFuture = mgr.revokeAll();

      // Start addVip() WHILE revoke's write is still stuck. Its own write
      // must queue strictly BEHIND revoke's in `_saveQueue` and must not
      // run until revoke's held write completes.
      final addFuture = mgr.addVip(
          key: 'C', duration: const Duration(hours: 1), stack: true);

      // Let every already-queued microtask run WITHOUT ever releasing
      // revoke's held write. If a queue-less implementation let addVip's
      // write fire independently, `store.raw` would already show it here.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(store.raw, isNull,
          reason: 'T176 — neither write may have landed yet: revoke\'s own '
              'write is deliberately held, and addVip\'s write must be '
              'queued strictly behind it, never running first');

      store.releaseNextWrite(); // let revoke's held write actually complete
      await Future.wait([revokeFuture, addFuture]);

      expect(mgr.isActive, isTrue,
          reason: 'addVip() logically came after revokeAll(), so its '
              'grant must survive');
      final reloaded = VipManager(prefs, vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.isActive, isTrue,
          reason: 'T176 — the final persisted write must be addVip\'s, '
              'landed strictly after the held revoke write completed, not '
              'raced ahead of it');
    });

    test('both orderings are deterministic across repeated runs (not '
        'flaky)', () async {
      for (var i = 0; i < 20; i++) {
        SharedPreferences.setMockInitialValues({});
        prefs = await AdPreferences.getInstance();
        store = _FakeVipEntriesStore(prefs);
        final mgr = VipManager(prefs, vipEntriesStore: store);
        await mgr.load();

        final addFuture = mgr.addVip(
            key: 'X', duration: const Duration(hours: 1), stack: true);
        final revokeFuture = mgr.revokeAll();
        await Future.wait([addFuture, revokeFuture]);
        expect(mgr.isActive, isFalse, reason: 'iteration $i');
        mgr.dispose();
      }
    });
  });
}
