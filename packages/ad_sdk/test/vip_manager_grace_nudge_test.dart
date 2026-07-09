// VIP grace-period expiry nudge: due once remaining VIP time crosses
// [VipManager.graceNudgeThreshold], one-time-per-expiry ack via AdPreferences.
//
// Backing store is the in-memory SharedPreferences mock, same pattern as
// vip_entitlement_flow_test.dart / vip_manager_robustness_test.dart.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    // Shared singleton store → wipe persisted entries for a clean slate.
    await VipManager(prefs).revokeAll();
  });

  test('not due when remaining time is well above threshold', () async {
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 100));
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
        graceNudgeThreshold: const Duration(milliseconds: 300));
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
        graceNudgeThreshold: const Duration(milliseconds: 300));
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
        graceNudgeThreshold: const Duration(milliseconds: 300));
    await reloaded.load();
    addTearDown(reloaded.dispose);
    expect(reloaded.graceNudgeDueListenable.value, isFalse);
  });

  test('stacking to a new expiresAt makes the nudge due again after ack',
      () async {
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 300));
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

  test('inactive/no-VIP state is never due', () async {
    final mgr = VipManager(prefs,
        graceNudgeThreshold: const Duration(milliseconds: 300));
    await mgr.load();
    addTearDown(mgr.dispose);

    expect(mgr.isActive, isFalse);
    expect(mgr.graceNudgeDueListenable.value, isFalse);
  });
}
