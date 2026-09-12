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

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory fake so this test doesn't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel. `async` (not synchronous) so it
/// behaves like the real store: a write is not instantaneous, it resolves on
/// a later microtask — same as production, where interleaving actually
/// matters.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? raw;
  @override
  Future<String?> getRaw() async => raw;
  @override
  Future<void> setRaw(String json) async => raw = json;
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
