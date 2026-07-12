// On-device integration test for the Interstitial demo (InterstitialDemoPage).
//
// HIGH VALUE: this exercises the exact code path where a real SDK
// race-condition was fixed this session (packages/ad_sdk/lib/src/adapters/
// applovin_adapter.dart + admob_adapter.dart — a smart-timeout watchdog could
// race against a late-arriving native dismiss callback and corrupt slot
// state / fire a duplicate unsafe ad load). This test drives the REAL
// show+dismiss flow (not just load) and shows the SAME show cycle can run
// twice cleanly right after, which is the failure mode that bug produced.
//
// IMPORTANT — on a physical iOS device there is no automated UI-automation
// tool available in this environment (unlike Simulator/Android), so a HUMAN
// must manually tap the interstitial's close/X button when it appears during
// this run. That is why the poll below uses a GENEROUS 60s timeout instead of
// a short fixed wait.
//
// Ad *content*/fill is never guaranteed, so assertions are lenient about
// whether an ad actually showed and strict about lifecycle/state/no-crash.
//
// Run with:
//   flutter test integration_test/interstitial_ad_test.dart -d <device-or-sim-id>
//
// Automated-equivalent unit coverage for the same show/dismiss state-machine
// logic (no manual tap required): test/interstitial_rewarded_watchdog_test.dart

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

/// Revoking the first-install VIP grace mid-test can unmask the SDK's
/// already-scheduled post-splash consent dialog (AdManager._maybeScheduleConsentDialog
/// re-checks VIP at its ~1s-delayed fire time, per ad_manager.dart) — it was
/// scheduled while VIP was still inactive-pending, then fires after our
/// revokeAll() call. Wait out that window and dismiss it if it shows, so it
/// doesn't swallow the tap meant for the demo tile underneath.
Future<void> _revokeVipGraceAndClearConsentDialog(WidgetTester tester) async {
  await AdManager().vip!.revokeAll();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
    final allow = find.text('Allow personalized ads');
    if (allow.evaluate().isNotEmpty) {
      await tester.tap(allow);
      await tester.pump(const Duration(milliseconds: 300));
      break;
    }
  }
}

/// Polls the interstitial slot back to a non-showing state (idle/ready/
/// cooldown — anything other than `showing`). This test polls for up to 60s
/// because a human must manually tap the ad's close button when it appears —
/// there is no automated real-device UI-automation tool available for iOS in
/// this environment.
Future<void> _waitForNotShowing(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final slot = AdManager().adapter?.interstitialSlot;
    if (slot == null || !slot.isShowing) return;
  }
  fail('interstitial slot never left the showing state within 60s — '
      'possible zombie state from the show/dismiss race');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'interstitial show+dismiss returns slot to a clean state, twice in a row',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Fresh installs auto-grant a first-install VIP grace window
    // (DemoConfig.firstInstallVipGrace) during which AdManager silently
    // no-ops every load/show call. Revoke it so this test actually exercises
    // the real ad show/dismiss lifecycle instead of trivially passing.
    await _revokeVipGraceAndClearConsentDialog(tester);

    final tile = find.text('Interstitial ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Interstitial ad tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Interstitial demo'), findsOneWidget);

    final showButton = find.widgetWithText(
        FilledButton, 'Show interstitial (placement: levelComplete)');
    expect(showButton, findsOneWidget);

    // ── Cycle 1 ────────────────────────────────────────────────────────────
    await tester.tap(showButton);
    await tester.pump(const Duration(milliseconds: 500));
    // A human taps the close/X button on the native ad when it appears.
    await _waitForNotShowing(tester);
    expect(tester.takeException(), isNull);

    // Give the demo's onDone callback a beat to update "Last: ..." text.
    await tester.pump(const Duration(milliseconds: 500));

    // ── Cycle 2 — proves no zombie/duplicate-load state lingers from cycle 1.
    await tester.tap(showButton);
    await tester.pump(const Duration(milliseconds: 500));
    await _waitForNotShowing(tester);

    expect(tester.takeException(), isNull);
  });
}
