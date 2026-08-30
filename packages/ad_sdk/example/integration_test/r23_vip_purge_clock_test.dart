// On-device integration test for round-23 BLOCKER V1 — a poisoned high-water
// clock mark must SUPPRESS a paid VIP entry, never DESTROY it.
//
// The unit test (`packages/ad_sdk/test/r23_purge_poisoned_clock_test.dart`)
// proves the branch against an in-memory fake store. That is not the same
// claim. The bug destroyed rows *on disk*, and "on disk" here means the real
// `flutter_secure_storage` (Keychain / EncryptedSharedPreferences) that
// `VipEntriesStore` writes through, with a real `SharedPreferences` holding the
// clock mark beside it. A guard that works against a Map and not against the
// real store would be worthless — this file is the one that says it works
// against the real store.
//
// Run with:
//   flutter test integration_test/r23_vip_purge_clock_test.dart -d <device-id>

import 'dart:convert';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Same budget reasoning as vip_clock_forward_test.dart: on a real device the
// splash chain sits behind the ATT prompt and the UMP form, each with its own
// ~20s internal timeout, before initialize() resolves.
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised && AdManager().vip != null) return;
  }
  fail('SDK must finish initialising on device');
}

/// `_purgeExpired` writes back through `unawaited(_save())`, and the write goes
/// out over a platform channel here. An assertion made on the next frame can
/// read the store before the write lands, which would make this test a coin
/// flip rather than a proof.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a paid VIP row survives a clock mark parked years in the future, '
      'on the real device store', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    final prefs = await AdPreferences.getInstance();
    final store = VipEntriesStore(prefs);

    await vip.revokeAll();
    await _settle(tester);

    // A real 10-day grant, taken while the clock is honest.
    await vip.addVip(key: 'R23-PURGE-DEVICE', duration: const Duration(days: 10));
    await _settle(tester);
    expect(vip.isActive, isTrue, reason: 'sanity — the grant must be live');

    // Now poison the mark the way a flat battery does: a boot with the date
    // years ahead, seen once, committed. No attacker involved.
    final poisoned = DateTime.now().add(const Duration(days: 400));
    await prefs.setVipMaxObservedClockMs(poisoned.millisecondsSinceEpoch);

    // `load()` is the path that runs the expiry sweep at every launch.
    await vip.load();
    await _settle(tester);

    // THE finding: before the fix this row was gone from disk, unrecoverably —
    // no backend, and the key id is already burned in the one-time-use ledger.
    final raw = await store.getRaw();
    expect(raw, isNotNull,
        reason: 'the entries record itself must still exist');
    expect(raw, contains('R23-PURGE-DEVICE'),
        reason: 'THE finding — a poisoned clock mark must not erase a paid '
            'grant from the real device store');

    final decoded = jsonDecode(raw!) as List;
    expect(decoded.length, 1,
        reason: 'exactly the one row, still there, not a rewritten empty list');

    // Suppressed, though — that is the accepted, documented cost of the
    // anti-rollback mark, and it is what makes this a suppression and not a
    // silent no-op.
    expect(vip.isActive, isFalse,
        reason: 'the mark still governs entitlement: suppress, never delete');
    expect(AdManager().isVIPMember(), isFalse,
        reason: 'and the gate the host actually reads agrees');

    // Correcting the clock brings the entitlement back — the whole point of
    // keeping the row.
    await prefs.setVipMaxObservedClockMs(
        DateTime.now().millisecondsSinceEpoch);
    await vip.load();
    await _settle(tester);

    expect(vip.isActive, isTrue,
        reason: 'once the mark is no longer ahead of real time the customer '
            'gets back the days they paid for');

    await vip.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
      'a grant stamped in the future survives a missing clock mark, on the '
      'real store', (tester) async {
    // Round-24 QC (reviewer A, MAJOR). The round-23 fix asked "are both clocks
    // saying it is not active?", which is also true while the clock reads
    // BEFORE `grantedAt` — so a future-stamped grant was still deleted. The
    // reachable shape is a device one: the VIP row is Keychain-backed and
    // survives an iOS reinstall, the high-water mark lives in SharedPreferences
    // and does not. That asymmetry is exactly what this file can exercise and a
    // VM test cannot.
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    final prefs = await AdPreferences.getInstance();
    final store = VipEntriesStore(prefs);

    await vip.revokeAll();
    await _settle(tester);

    final granted = DateTime.now().add(const Duration(days: 30));
    final entry = VipEntry(
      key: 'R23-FUTURE-DEVICE',
      grantedAt: granted,
      expiresAt: granted.add(const Duration(days: 90)),
    );
    await store.setRaw(jsonEncode([entry.toJson()]));
    await prefs.setVipMaxObservedClockMs(0); // the mark did not survive

    await vip.load();
    await _settle(tester);

    expect(await store.getRaw(), contains('R23-FUTURE-DEVICE'),
        reason: 'the window has not STARTED, let alone ended — deleting it '
            'destroys a paid key whose id is already burned in the ledger');
    expect(vip.isActive, isFalse,
        reason: 'and it is still correctly suppressed until its window opens');

    await vip.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets(
      'CONTROL — a genuinely expired row is still removed from the real store',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    final prefs = await AdPreferences.getInstance();
    final store = VipEntriesStore(prefs);

    await vip.revokeAll();
    await _settle(tester);

    // Write an already-dead row straight into the real store, then let the
    // sweep see it. If the fix had been "never delete anything", this test
    // goes red and the purge would grow the record without bound.
    final dead = VipEntry(
      key: 'R23-PURGE-DEAD',
      grantedAt: DateTime.now().subtract(const Duration(days: 30)),
      expiresAt: DateTime.now().subtract(const Duration(days: 20)),
    );
    await store.setRaw(jsonEncode([dead.toJson()]));
    await prefs.setVipMaxObservedClockMs(
        DateTime.now().millisecondsSinceEpoch);

    await vip.load();
    await _settle(tester);

    final raw = await store.getRaw();
    expect(raw ?? '[]', isNot(contains('R23-PURGE-DEAD')),
        reason: 'both clocks agree this one is over, so housekeeping must '
            'still do its job');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
