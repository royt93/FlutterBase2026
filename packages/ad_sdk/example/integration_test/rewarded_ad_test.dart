// On-device integration test for the Rewarded demo (RewardedDemoPage).
//
// HIGH VALUE: same bug class as interstitial_ad_test.dart — this session
// fixed a race in packages/ad_sdk/lib/src/adapters/applovin_adapter.dart +
// admob_adapter.dart where a 20s smart-timeout watchdog for App-Open could
// race a late native dismiss callback and corrupt slot state / trigger a
// duplicate unsafe ad load. Rewarded shares the same fullscreen show/dismiss
// plumbing, so this test drives the REAL show+dismiss flow twice in a row to
// prove no zombie state lingers.
//
// IMPORTANT — on a physical iOS device there is no automated UI-automation
// tool available in this environment (unlike Simulator/Android), so a HUMAN
// must manually tap the rewarded ad's close/X button when it appears during
// this run. That is why the poll below uses a GENEROUS 60s timeout instead of
// a short fixed wait.
//
// Ad *content*/fill (and whether the reward was actually earned) is never
// guaranteed, so assertions are lenient about that and strict about
// lifecycle/state/no-crash.
//
// Run with:
//   flutter test integration_test/rewarded_ad_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

/// This test polls for up to 60s because a human must manually tap the ad's
/// close button when it appears — there is no automated real-device
/// UI-automation tool available for iOS in this environment.
Future<void> _waitForNotShowing(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final slot = AdManager().adapter?.rewardedSlot;
    if (slot == null || !slot.isShowing) return;
  }
  fail('rewarded slot never left the showing state within 60s — '
      'possible zombie state from the show/dismiss race');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'rewarded show+dismiss returns slot to a clean state, twice in a row',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Fresh installs auto-grant a first-install VIP grace window (see
    // DemoConfig.firstInstallVipGrace), which silently no-ops every show
    // call below (pre-check fails, slot never enters `showing`) and would
    // make this test pass without ever exercising the real ad lifecycle.
    // Revoke it for a deterministic run regardless of device install history.
    await AdManager().vip!.revokeAll();
    await tester.pump();

    final tile = find.text('Rewarded ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Rewarded ad tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Rewarded demo'), findsOneWidget);

    final showButton =
        find.widgetWithText(FilledButton, 'Watch ad for +10 coins');
    expect(showButton, findsOneWidget);

    // ── Cycle 1 ────────────────────────────────────────────────────────────
    await tester.tap(showButton);
    await tester.pump(const Duration(milliseconds: 500));
    // A human taps the close/X button on the native ad when it appears.
    await _waitForNotShowing(tester);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 500));

    // ── Cycle 2 — proves no zombie/duplicate-load state lingers from cycle 1.
    await tester.tap(showButton);
    await tester.pump(const Duration(milliseconds: 500));
    await _waitForNotShowing(tester);

    expect(tester.takeException(), isNull);
  });
}
