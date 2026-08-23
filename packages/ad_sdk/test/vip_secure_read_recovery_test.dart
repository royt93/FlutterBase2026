// Round-7 audit, MAJOR — a secure-storage read that FAILED used to be
// indistinguishable from a secure store that is simply empty: `_readSecure()`
// returned null for both, `getRaw()` short-circuited to null once migration was
// marked done, and `load()` decoded an empty entry list. A paying VIP whose
// Keychain/Keystore hiccuped once at startup was therefore shown ads for the
// WHOLE session — nothing ever asked the store again — and no attacker was
// needed to trigger it.
//
// The pre-existing round-6 test for a transient read error always planted a
// plaintext fallback, so the far more common production state (the grant lives
// only in secure storage) had no coverage at all.
//
// Mocked at the layer BELOW the store — the FlutterSecureStorage it talks to —
// so the real `getRaw`/`load` code runs, for the reason spelled out at the top
// of `vip_untrusted_fallback_test.dart`.

import 'dart:async';

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PlatformExceptionStub implements Exception {}

/// An in-memory secure store whose `read` throws for the first
/// [failNextReads] calls and works normally afterwards — a Keystore that is
/// briefly unavailable (platform channel not up yet, device not unlocked since
/// boot) rather than one that is permanently broken.
class _FlakySecureStorage extends FlutterSecureStorage {
  _FlakySecureStorage({this.failNextReads = 0});

  int failNextReads;
  int reads = 0;
  final Map<String, String> data = {};

  /// When set, `read` waits on this before answering — lets a test land
  /// `dispose()` while a load is parked mid-await.
  Completer<void>? readGate;

  /// Parks writes, so a test can have a grant exist in memory while its own
  /// save is still in flight.
  Completer<void>? writeGate;

  /// Writes that have REACHED the platform call (as opposed to sitting in
  /// `VipManager`'s queue) — lets a test park a write that is genuinely in
  /// flight, which is the only kind the disposed check cannot catch.
  int writesStarted = 0;


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
    reads++;
    // Snapshot BEFORE parking: a real platform read that has already fetched
    // and is only waiting for its Dart future to resolve returns what storage
    // held when it ran, not what it holds when the caller finally sees it.
    final snapshot = data[key];
    final gate = readGate;
    if (gate != null) await gate.future;
    if (failNextReads > 0) {
      failNextReads--;
      throw _PlatformExceptionStub();
    }
    return snapshot;
  }

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
    writesStarted++;
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
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
    data.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    // The save queue is process-wide. A `Future` propagates its completion in
    // the zone that CREATED it, so a tail left behind by an earlier test's
    // `fakeAsync` zone never settles for anyone else — reset it per test, and
    // again inside each fake zone (a tail created out here is invisible to
    // that zone's `flushMicrotasks`, so every save chained onto it stalls).
    VipManager.resetSaveQueueForTest();
    prefs = await AdPreferences.getInstance();
    // The production state this bug lives in: migration long since done, so
    // `getRaw()` never consults the legacy key, and NO plaintext fallback —
    // the grant exists only in secure storage.
    await prefs.markVipEntriesSecureMigrated();
  });

  /// A real, in-date grant sitting in secure storage, the way a paying
  /// customer's device looks at launch.
  String genuineGrant() {
    final now = DateTime.now().toUtc();
    return '[{"key":"SIGNED_ABC",'
        '"expiresAt":"${now.add(const Duration(days: 30)).toIso8601String()}",'
        '"grantedAt":"${now.subtract(const Duration(days: 1)).toIso8601String()}"}]';
  }

  test('a single failed secure read does not cost a paying VIP their grant',
      () async {
    final secure = _FlakySecureStorage(failNextReads: 1);
    secure.data['ad_sdk_vip_entries_v1'] = genuineGrant();
    final mgr = VipManager(prefs, vipEntriesStore: VipEntriesStore(prefs, secureStorage: secure));
    addTearDown(mgr.dispose);

    await mgr.load();

    expect(secure.reads, greaterThanOrEqualTo(2),
        reason: 'the in-line retry must actually have re-read the store');
    expect(mgr.isActive, isTrue,
        reason: 'one Keystore blip must not read as "this customer has no VIP"');
  });

  test('a store unreadable at startup restores the grant within the session',
      () {
    final secure = _FlakySecureStorage(failNextReads: 2);
    secure.data['ad_sdk_vip_entries_v1'] = genuineGrant();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();

      expect(mgr.isActive, isFalse,
          reason: 'both in-line attempts failed — nothing to grant yet');

      // A locked device (Keychain `first_unlock`) stays unreadable for far
      // longer than an in-line retry can wait out, which is why the recovery
      // is timed rather than a tighter loop.
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();

      expect(mgr.isActive, isTrue,
          reason: 'the retry re-ran load() once the store came back — without '
              'it the customer sees ads until they kill and reopen the app');
      mgr.dispose();
    });
  });

  test('a healthy store that is genuinely empty schedules no retry', () {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();
      final readsAfterLoad = secure.reads;

      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();

      expect(secure.reads, readsAfterLoad,
          reason: '"no VIP" from a store that answered fine is a final answer; '
              'polling it forever would be pure battery cost');
      expect(async.pendingTimers, isEmpty);
      mgr.dispose();
    });
  });

  test('a permanently broken store stops retrying instead of polling forever',
      () {
    final secure = _FlakySecureStorage(failNextReads: 1 << 30);
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();

      async.elapse(const Duration(minutes: 10));
      async.flushMicrotasks();
      final readsAfterAllRetries = secure.reads;

      async.elapse(const Duration(hours: 1));
      async.flushMicrotasks();

      expect(secure.reads, readsAfterAllRetries,
          reason: 'the schedule is bounded — a device with an unusable '
              'Keystore must not spin platform calls for the whole session');
      expect(async.pendingTimers, isEmpty);
      mgr.dispose();
    });
  });

  // Round-8 QC, MAJOR (codex). Cancelling a WAITING retry is not enough: once
  // the retry timer has fired, the load is already parked on the read, and its
  // first act on return is `_entries.clear()`. A grant that arrives in that
  // window is wiped from memory — and its own save may not have landed yet, so
  // the reload finds nothing either. A paying customer loses the entitlement
  // they just redeemed, for the whole session.
  test('a grant that lands while a retry read is in flight is not wiped by it',
      () {
    // First read fails (so a retry gets armed); the retry's read hangs on the
    // gate, which is when the grant arrives.
    final secure = _FlakySecureStorage(failNextReads: 2);
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();
      expect(mgr.isActive, isFalse, reason: 'sanity: nothing readable yet');

      // Park the retry's read mid-flight.
      final gate = Completer<void>();
      secure.readGate = gate;
      async.elapse(const Duration(seconds: 3)); // fires the 2s retry
      async.flushMicrotasks();

      // The grant lands while that read is still parked.
      unawaited(mgr.addVip(key: 'MANUAL', duration: const Duration(days: 7)));
      async.flushMicrotasks();
      expect(mgr.isActive, isTrue, reason: 'sanity: the grant landed');

      // Now the stale read finally answers.
      gate.complete();
      secure.readGate = null;
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();

      expect(mgr.isActive, isTrue,
          reason: 'a read that started BEFORE the grant must not overwrite the '
              'state that grant produced — whoever wrote last wins, and the '
              'in-memory state is newer than the read by definition');
      mgr.dispose();
    });
  });

  // Round-9 QC, MAJOR (codex). The epoch check protects the load that is
  // reading, but not the one QUEUED behind it: that one snapshots the already
  // bumped epoch and can still read storage before the grant's save has landed.
  // It then accepts a read taken before the grant existed, clears it, and the
  // next save writes the cleared list — the entitlement is gone from disk, not
  // just from memory.
  test('a load queued behind a grant waits for that grant to be persisted', () {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);

      // Load A parks on its read; load B queues behind it.
      final gateA = Completer<void>();
      secure.readGate = gateA;
      unawaited(mgr.load());
      async.flushMicrotasks();
      unawaited(mgr.load());
      async.flushMicrotasks();

      // The grant lands, with its own save parked: memory has it, disk has not.
      final writeGate = Completer<void>();
      secure.writeGate = writeGate;
      unawaited(mgr.addVip(key: 'MANUAL', duration: const Duration(days: 7)));
      async.flushMicrotasks();

      // A comes back and correctly abandons its stale read; B now runs.
      secure.readGate = null;
      gateA.complete();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      // The grant's save finally lands.
      secure.writeGate = null;
      writeGate.complete();
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();

      expect(mgr.isActive, isTrue,
          reason: 'the queued load must not accept a read taken before the '
              'grant was persisted — doing so clears the grant and the next '
              'save writes the cleared list to disk');
      expect(secure.data['ad_sdk_vip_entries_v1'], contains('MANUAL'),
          reason: 'and the entitlement must still be on disk');
      mgr.dispose();
    });
  });

  // Round-9 QC, MAJOR (codex). Only the first read was guarded, so a manager
  // disposed during one of `_load`'s later awaits (clamp persistence, migration
  // persistence, revocation clamping) still reached storage. On a destroy +
  // re-init the replacement manager owns that same key, so a late write from
  // the discarded one resurrects entries the live manager already revoked.
  test('a disposed manager cannot write storage', () async {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    final live = VipManager(prefs, vipEntriesStore: store);
    await live.load();
    await live.addVip(key: 'MANUAL', duration: const Duration(days: 7));
    expect(live.isActive, isTrue, reason: 'sanity: the grant landed');

    // The host tears the SDK down but something still holds this reference.
    live.dispose();
    await live.revokeAll();

    expect(secure.data['ad_sdk_vip_entries_v1'], contains('MANUAL'),
        reason: 'a discarded manager must not wipe the store the replacement '
            'manager reads from');
  });

  // Round-7 final QC, found independently by BOTH reviewers — `dispose()`
  // cancels a PENDING retry, but a load whose timer had already fired was
  // parked on secure storage, and came back afterwards to mutate entries, push
  // the notifier, add to an already-closed stream and arm fresh timers. On a
  // host that re-inits (AdManager.destroy() then initialize()) that is a
  // discarded manager with a heartbeat.
  test('a load parked mid-read does not come back to life after dispose', () {
    final secure = _FlakySecureStorage(failNextReads: 1 << 30);
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final gate = Completer<void>();
      secure.readGate = gate;
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();

      mgr.dispose();
      // The read the disposed manager was waiting on finally answers.
      gate.complete();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      final readsAtDispose = secure.reads;

      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();

      // Counted rather than asserting on `pendingTimers` at the end: the retry
      // schedule is bounded, so five minutes later it has exhausted itself
      // either way and an empty timer list proves nothing.
      expect(secure.reads, readsAtDispose,
          reason: 'a disposed manager must not keep firing load() at '
              '2s/10s/45s on an object the host threw away');
      expect(mgr.isActive, isFalse);
    });
  });

  // Round-7 final QC — a grant that arrives while a retry is pending. Re-reading
  // is pointless at best, and could drop the fresh grant from memory if its own
  // save has not landed yet.
  test('a grant redeemed during the retry wait cancels the retry', () {
    final secure = _FlakySecureStorage(failNextReads: 2);
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();
      expect(mgr.isActive, isFalse);

      unawaited(mgr.addVip(key: 'MANUAL', duration: const Duration(days: 7)));
      async.flushMicrotasks();
      expect(mgr.isActive, isTrue, reason: 'sanity: the grant landed');
      final readsAfterGrant = secure.reads;

      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();

      expect(secure.reads, readsAfterGrant,
          reason: 'the pending retry must not re-read the store over a live '
              'grant: pointless at best, and it drops the grant from memory if '
              "the grant's own save has not landed yet");
      expect(mgr.isActive, isTrue);
      mgr.dispose();
    });
  });

  // Round-10 QC, MAJOR — the save queue used to be per-instance, so a write a
  // discarded manager had already STARTED could land after the replacement
  // manager's write and resurrect the entitlement the live one just wrote over.
  // (A write still sitting in the queue is caught by the disposed check; one
  // already inside the platform call is not — only ordering saves that case.)
  test('a write started by a discarded manager cannot land on top of its '
      'replacement', () async {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    final inFlight = Completer<void>();
    secure.writeGate = inFlight;
    final old = VipManager(prefs, vipEntriesStore: store);
    await old.load();
    final oldWrite = old.addVip(key: 'OLD', duration: const Duration(days: 7));
    // Let it reach the platform call before the teardown — past the point any
    // disposed check can help.
    while (secure.writesStarted == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    old.dispose();

    // The host re-inits: `AdManager.initialize()` always loads before anything
    // else, so the replacement must see the write the old manager still has in
    // flight — and only then write its own state.
    final live = VipManager(prefs, vipEntriesStore: store);
    addTearDown(live.dispose);
    secure.writeGate = null;
    final readsBefore = secure.reads;
    final loaded = live.load();
    await pumpEventQueue();
    expect(secure.reads, readsBefore,
        reason: 'the replacement must still be waiting for the pending write, '
            'not reading around it');
    inFlight.complete();
    await loaded;
    expect(live.entries.map((e) => e.key), contains('OLD'),
        reason: 'the replacement must not read pre-grant data while a write '
            'from the manager it replaced is still in flight');
    final liveWrite =
        live.addVip(key: 'NEW', duration: const Duration(days: 7));

    await oldWrite;
    await liveWrite;

    expect(secure.data['ad_sdk_vip_entries_v1'], contains('NEW'),
        reason: 'the live manager wrote last, so its state is what must be on '
            'disk — a write from a manager the host threw away cannot win');
  });

  // Round-10 QC, MAJOR — the disposed check used to run only when `_save()` was
  // CALLED. A write queued behind another one can wait long enough for the host
  // to tear the SDK down, and by then the store belongs to the replacement.
  test('a write already queued when dispose happens is dropped', () async {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    await mgr.addVip(key: 'MANUAL', duration: const Duration(days: 7));

    // Park the head of the queue, put a revoke behind it, THEN dispose: the
    // revoke was legal when it was called and only became illegal while it sat
    // in the queue.
    final parked = Completer<void>();
    secure.writeGate = parked;
    final blocker =
        mgr.addVip(key: 'BLOCKER', duration: const Duration(days: 1));
    while (secure.writesStarted < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    final queued = mgr.revokeAll();
    mgr.dispose();
    secure.writeGate = null;
    parked.complete();
    await blocker;
    await queued;

    expect(secure.data['ad_sdk_vip_entries_v1'], contains('MANUAL'),
        reason: 'a write that reaches the head of the queue after dispose must '
            'be dropped, not written over the live store');
  });

  // Round-10 QC, MAJOR — the drain that makes a load wait for pending writes
  // must be bounded: `AdManager.initialize()` awaits `load()`, so a platform
  // write that never answers would hang SDK startup for good.
  test('a load whose pending write never lands gives up and retries', () {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();
      unawaited(mgr.addVip(key: 'MANUAL', duration: const Duration(days: 7)));
      async.flushMicrotasks();

      // A write that never answers, and a load behind it.
      secure.writeGate = Completer<void>();
      unawaited(mgr.addVip(key: 'OTHER', duration: const Duration(days: 7)));
      async.flushMicrotasks();
      var loadReturned = false;
      unawaited(mgr.load().then((_) => loadReturned = true));
      async.flushMicrotasks();
      expect(loadReturned, isFalse, reason: 'sanity: the load is draining');

      async.elapse(VipManager.kSaveDrainTimeout + const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(loadReturned, isTrue,
          reason: 'the drain must time out rather than hang SDK startup on a '
              'wedged platform write');
      expect(mgr.isActive, isTrue,
          reason: 'giving up on the drain must keep the in-memory grant, not '
              'trust a read it never took');
      mgr.dispose();
    });
  });

  // Round-10 QC, MINOR — the one-shot 1.x GAID migration must not be marked
  // done when the write that carries it may have been dropped: the flag makes
  // every later launch skip migration, losing the legacy entitlement for good.
  test('a dispose mid-migration does not mark the 1.x migration done',
      () async {
    await prefs.saveGAIDList(<String>['gaid-1']);
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    final parked = Completer<void>();
    secure.writeGate = parked;
    final mgr = VipManager(prefs, vipEntriesStore: store);
    final loading = mgr.load(currentDeviceGaid: 'gaid-1');
    while (secure.writesStarted == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    mgr.dispose();
    secure.writeGate = null;
    parked.complete();
    await loading;

    expect(prefs.isVipMigrated(), isFalse,
        reason: 'the migration flag must only be set once its write is known '
            'to have landed on a live manager');
  });

  // Round-10 QC, MAJOR — the epoch has to be snapshotted BEFORE the drain, not
  // after. A grant that lands *while* the drain is waiting queues its own write
  // behind the one being drained, so the read that follows can still predate
  // it: with the snapshot taken afterwards the load sees "nothing changed",
  // accepts a read that never contained the grant, and drops it.
  test('a grant that lands during the drain is not dropped by the read after '
      'it', () {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      unawaited(mgr.load());
      async.flushMicrotasks();

      // A parked write, so the next load's drain has something to wait on.
      final first = Completer<void>();
      secure.writeGate = first;
      unawaited(mgr.addVip(key: 'FIRST', duration: const Duration(days: 7)));
      async.flushMicrotasks();

      // The load starts and parks in the drain.
      unawaited(mgr.load());
      async.flushMicrotasks();

      // The grant arrives while the drain waits; its own write queues behind
      // the parked one and is itself parked, so storage never gets it.
      unawaited(mgr.addVip(key: 'SECOND', duration: const Duration(days: 7)));
      async.flushMicrotasks();
      secure.writeGate = Completer<void>();
      first.complete();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(mgr.entries.map((e) => e.key), contains('SECOND'),
          reason: 'the read was taken before the grant existed, so it cannot '
              'be what the session runs on');
      mgr.dispose();
    });
  });

  // Round-12 QC, MAJOR (both reviewers) — writes are STRICTLY ordered. A
  // bounded wait here was tried and reverted: it put two writes in flight over
  // the same key, and the one that was given up on could still land last and
  // leave a stale snapshot on disk. The queue must make a later write land
  // later, full stop, even behind a platform call that has wedged.
  test('a later write cannot jump ahead of a wedged one', () {
    final secure = _FlakySecureStorage();
    final store = VipEntriesStore(prefs, secureStorage: secure);

    fakeAsync((async) {
      VipManager.resetSaveQueueForTest(); // must happen INSIDE the fake zone
      final mgr = VipManager(prefs, vipEntriesStore: store);
      addTearDown(mgr.dispose);
      unawaited(mgr.load());
      async.flushMicrotasks();

      // A write that hangs inside the platform call, far longer than any bound.
      final hung = Completer<void>();
      secure.writeGate = hung;
      unawaited(mgr.addVip(key: 'OLD', duration: const Duration(days: 7)));
      async.flushMicrotasks();
      expect(secure.writesStarted, greaterThan(0),
          reason: 'sanity: the hung write is inside the platform call');
      secure.writeGate = null;

      // The revoke that follows it must not overtake it.
      unawaited(mgr.revokeAll());
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(secure.data['ad_sdk_vip_entries_v1'], isNull,
          reason: 'nothing may reach disk while the write ahead of it has not '
              'answered — a write that goes around it can still land last');

      hung.complete();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(secure.data['ad_sdk_vip_entries_v1'], isNot(contains('OLD')),
          reason: 'once the wedged write clears, the revoke behind it is what '
              'disk must hold');
    });
  });
}
