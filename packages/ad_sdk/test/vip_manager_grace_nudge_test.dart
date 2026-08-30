// VIP grace-period expiry nudge: due once remaining VIP time crosses
// [VipManager.graceNudgeThreshold], one-time-per-expiry ack via AdPreferences.
//
// Backing store is the in-memory SharedPreferences mock, same pattern as
// vip_entitlement_flow_test.dart / vip_manager_robustness_test.dart.

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

  test('not due when remaining time is well above threshold', () async {
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 100),
        vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'FAR', duration: const Duration(hours: 1));

    expect(mgr.graceNudgeDueListenable.value, isFalse);
  });

  test(
      'becomes due once remaining time crosses the threshold '
      '(covers _scheduleNextExpiry/_handleExpiry)', () async {
    // NOTE: real (not fakeAsync) delay — VipManager reads wall-clock
    // DateTime.now() directly, same rationale as the mid-session expiry
    // timer test in vip_entitlement_flow_test.dart.
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 300),
        vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'SOON', duration: const Duration(milliseconds: 400));
    expect(mgr.graceNudgeDueListenable.value, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(mgr.graceNudgeDueListenable.value, isTrue,
        reason: 'remaining time (~200ms) now within the 300ms threshold');
  });

  test('acknowledgeGraceNudge() persists and suppresses re-nudge', () async {
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 300),
        vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'SOON', duration: const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(mgr.graceNudgeDueListenable.value, isTrue);

    mgr.acknowledgeGraceNudge();
    expect(mgr.graceNudgeDueListenable.value, isFalse);

    // Reloading a fresh manager against the same persisted expiry must not
    // re-surface the nudge — the ack is keyed on expiresAt, not the instance.
    final reloaded = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 300),
        vipEntriesStore: store);
    await reloaded.load();
    addTearDown(reloaded.dispose);
    expect(reloaded.graceNudgeDueListenable.value, isFalse);
  });

  test('stacking to a new expiresAt makes the nudge due again after ack',
      () async {
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 300),
        vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    await mgr.addVip(key: 'SOON', duration: const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(mgr.graceNudgeDueListenable.value, isTrue);

    mgr.acknowledgeGraceNudge();
    expect(mgr.graceNudgeDueListenable.value, isFalse);

    // A new, later expiry (stack) is now far from the threshold again.
    await mgr.addVip(
        key: 'EXTEND', duration: const Duration(hours: 1), stack: true);
    expect(mgr.graceNudgeDueListenable.value, isFalse,
        reason: 'new expiresAt pushed well beyond threshold');

    await mgr.revokeAll();
    await mgr.addVip(key: 'SOON2', duration: const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(mgr.graceNudgeDueListenable.value, isTrue,
        reason: 'different expiresAt than the acknowledged one is due again');
  });

  // ─── Round-23 audit, MAJOR: the nudge must land in the second half of the
  // granted window, never at grant time. The default threshold (24h) is
  // exactly the default first-install trial length, so unclamped it fired the
  // instant a brand-new user got their trial.
  group('grace nudge is clamped to half the granted window (round 23)', () {
    test('a 24h grant with the default 24h threshold is NOT due at grant time',
        () async {
      final mgr = VipManager(prefs, vipEntriesStore: store); // default 24h
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.addVip(key: 'TRIAL', duration: const Duration(hours: 24));

      expect(mgr.graceNudgeDueListenable.value, isFalse,
          reason: 'a first-install trial must not open with '
              '"your VIP is about to run out"');
    });

    test('an hour-long grant with the default 24h threshold is NOT due either',
        () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.addVip(key: 'PROMO', duration: const Duration(hours: 1));

      expect(mgr.graceNudgeDueListenable.value, isFalse);
    });

    test('the nudge still fires, at half the window', () async {
      // Threshold far larger than the grant, so only the clamp can hold it
      // back — then it must become due once half the window is gone.
      final mgr = VipManager(prefs,
          graceNudgeThreshold: const Duration(hours: 1),
          vipEntriesStore: store);
      await mgr.load();
      addTearDown(mgr.dispose);

      await mgr.addVip(key: 'SHORT', duration: const Duration(milliseconds: 600));
      expect(mgr.graceNudgeDueListenable.value, isFalse,
          reason: 'clamped to 300ms, 600ms still remaining');

      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(mgr.graceNudgeDueListenable.value, isTrue,
          reason: 'under 300ms left — second half of the window');
    });

    // Round-23 audit, MINOR (independent review) — the tests above prove the
    // clamp inside a live manager, where the entry was granted in-process. The
    // timer that actually wakes the app up is armed by `_scheduleNextExpiry`
    // from persisted state on `load()`, and that path computes its own
    // `nudgeFireAt`. This drives it: a fresh manager reading the SAME store
    // must arm the nudge at the clamped time, not at the raw threshold (which
    // would make it due the moment `load()` returns).
    test('a manager that RELOADS the grant arms the nudge at the clamped time',
        () async {
      final first = VipManager(prefs,
          graceNudgeThreshold: const Duration(hours: 1),
          vipEntriesStore: store);
      await first.load();
      await first.addVip(
          key: 'SHORT', duration: const Duration(milliseconds: 600));
      first.dispose();

      final reloaded = VipManager(prefs,
          graceNudgeThreshold: const Duration(hours: 1),
          vipEntriesStore: store);
      await reloaded.load();
      addTearDown(reloaded.dispose);

      expect(reloaded.isActive, isTrue);
      expect(reloaded.graceNudgeDueListenable.value, isFalse,
          reason: 'clamped to 300ms — over 300ms still remaining');

      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(reloaded.graceNudgeDueListenable.value, isTrue,
          reason: 'the timer armed from persisted state must have fired');
    });
  });

  test('inactive/no-VIP state is never due', () async {
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 300),
        vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);

    expect(mgr.isActive, isFalse);
    expect(mgr.graceNudgeDueListenable.value, isFalse);
  });
}
