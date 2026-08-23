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
    final gate = readGate;
    if (gate != null) await gate.future;
    if (failNextReads > 0) {
      failNextReads--;
      throw _PlatformExceptionStub();
    }
    return data[key];
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
}
