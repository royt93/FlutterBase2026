// On-device integration test for MJ9 — a device clock parked in the future must
// not be able to mint a VIP that never expires.
//
// The unit test (packages/ad_sdk/test/vip_manager_robustness_test.dart, group
// "MJ9") already covers the logic against an in-memory store. This one is here
// because MJ9 lives entirely in the interaction between two persisted values —
// the anti-rollback high-water mark and an entry's `grantedAt` — and on device
// those go through the real native shared_preferences plugin and the real
// Keychain-backed entries store, not a fake. A guard that works against a map
// and not against the real store would be worthless.
//
// Run with:
//   flutter test integration_test/vip_clock_forward_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Same budget and reasoning as vip_redeem_flow_test.dart's copy: on a real
// device the splash chain can sit behind the ATT prompt and the UMP form, each
// with its own ~20s internal timeout, before initialize() resolves.
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised && AdManager().vip != null) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a grant stamped a year ahead does not entitle anything once the clock '
      'is usable again, and is not deleted', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    final prefs = await AdPreferences.getInstance();

    // A fresh install auto-grants the first-install trial, and this device may
    // carry state from an earlier run — start from a known-empty entitlement.
    await vip.revokeAll();
    final realNow = DateTime.now();
    addTearDown(() async {
      await vip.revokeAll();
      // revokeAll() deliberately does not touch the high-water mark (a wipe
      // must not hand an abuser a fresh clock), so put it back by hand or every
      // later test on this device inherits a mark parked a year out.
      await prefs.setVipMaxObservedClockMs(
          DateTime.now().millisecondsSinceEpoch);
    });

    // Step 1+2 of the exploit: the app has observed the clock a year ahead
    // (which is what a real forward clock edit leaves behind), and a grant is
    // taken while it is parked there. addVip anchors to that mark on purpose —
    // that is the anti-rollback behaviour, not the bug.
    final parked = realNow.add(const Duration(days: 365));
    await prefs.setVipMaxObservedClockMs(parked.millisecondsSinceEpoch);
    final entry = await vip.addVip(
        key: 'MJ9-DEVICE', duration: const Duration(days: 10));
    expect(entry.expiresAt.isAfter(parked), isTrue,
        reason: 'sanity check — the grant must be stamped from the mark, '
            'otherwise this test is not reproducing the exploit at all');

    // Step 3: the clock is corrected. The mark stays parked in the future —
    // deliberately left alone here, because that is the whole point: the only
    // thing that can reject this entry is the raw-clock start guard.
    expect(vip.isActive, isFalse,
        reason: 'MJ9 — an entry whose granted window has not begun on the '
            'real device clock must not entitle anything');
    expect(vip.expiresAt, isNull,
        reason: 'a not-yet-started entry must not be reported as the '
            'active VIP window');
    expect(AdManager().isVIPMember(), isFalse,
        reason: 'and the ad-suppression gate the host actually reads must '
            'agree — that is the surface the exploit was worth money on');

    // …and the honest half of the same state: a customer whose device clock was
    // genuinely fast when they paid must keep the row, suppressed rather than
    // purged. Read it back through a reload so this asserts what is on disk,
    // not just what is in memory.
    expect(vip.entries.map((e) => e.key), contains('MJ9-DEVICE'),
        reason: 'suppress, never delete');
    await vip.load();
    expect(vip.entries.map((e) => e.key), contains('MJ9-DEVICE'),
        reason: 'the suppressed entry must survive a reload from the real '
            'native store, not only live in memory');
    expect(vip.isActive, isFalse,
        reason: 'and it must still be suppressed after that reload');
  });
}
