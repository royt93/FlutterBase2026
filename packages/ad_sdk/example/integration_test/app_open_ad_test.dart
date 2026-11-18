// On-device integration test for the App-Open demo (AppOpenDemoPage).
//
// HIGHEST VALUE of the three fullscreen-format tests: this is the EXACT code
// path this session's SDK fix targeted — a 20s smart-timeout watchdog for
// App-Open (packages/ad_sdk/lib/src/adapters/applovin_adapter.dart +
// admob_adapter.dart) could race against a late-arriving native dismiss
// callback and corrupt slot state / fire a duplicate unsafe ad load. Fixed by
// a guard on the `_appOpenDismiss == null` sentinel. This test drives the
// REAL load → show → dismiss flow (not just load) and repeats the show cycle
// to prove no zombie/duplicate-load state lingers.
//
// IMPORTANT — on a physical iOS device there is no automated UI-automation
// tool available in this environment (unlike Simulator/Android), so a HUMAN
// must manually tap the App-Open ad's close/X button when it appears during
// this run. That is why the poll below uses a GENEROUS 60s timeout instead of
// a short fixed wait.
//
// Requires filled Google test ads and a manual native close for each cycle.
// Missing fill or display fails this test; it is not show/dismiss evidence.
//
// Run with:
//   flutter test integration_test/app_open_ad_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scroll_helpers.dart';

// On a real device the splash flow can hit BOTH the real ATT system prompt
// AND a real UMP consent form before initialize() ever completes -- each
// has its own internal 20s timeout when nothing dismisses it headlessly (see
// AttConsent's `requestAttIfNeeded` / UmpConsent's dismiss-timeout log line),
// so worst case is ~40s of that alone before init even starts resolving.
// Budget well past that (same fix already applied in
// debug_overlay_doctor_test.dart -- 2026-08-18 fork-review: this file hit the
// tighter 30s window's real failure mode on-device).
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

/// Polls until the App Open slot reports `ready` (loaded successfully) or
/// `cooldown` (load failed) — either is an acceptable terminal state for a
/// *load*, we just must not hang forever if fill is unavailable.
Future<bool> _waitForAppOpenLoaded(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final slot = AdManager().adapter?.appOpenSlot;
    if (slot == null) continue;
    if (slot.isReady) return true;
    if (slot.isCooldown) return false;
  }
  return false;
}

/// Round 44 — used to also dismiss the SDK's built-in post-splash consent
/// dialog if `revokeAll()` unmasked it mid-test; that dialog was removed
/// (round-44 audit finding 1), so this is just the VIP-grace revoke now.
Future<void> _revokeVipGrace(WidgetTester tester) async {
  await AdManager().vip!.revokeAll();
  await tester.pump(const Duration(milliseconds: 300));
}

/// This test polls for up to 60s because a human must manually tap the ad's
/// close button when it appears — there is no automated real-device
/// UI-automation tool available for iOS in this environment.
Future<void> _waitForNotShowing(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final slot = AdManager().adapter?.appOpenSlot;
    if (slot == null || !slot.isShowing) return;
  }
  fail('app-open slot never left the showing state within 60s — '
      'possible zombie state from the show/dismiss race this session fixed');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'App Open load+show+dismiss returns slot to a clean state, twice in a row',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Fresh installs auto-grant a first-install VIP grace window
    // (DemoConfig.firstInstallVipGrace) during which AdManager silently
    // no-ops every load/show call. Revoke it so this test actually exercises
    // the real ad show/dismiss lifecycle instead of trivially passing.
    await _revokeVipGrace(tester);

    final tile = find.text('App-open ad');
    var foundTile = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('Banner ad').evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'must navigate to HomePage');

    // Below the fold at the device's default density; scroll instead of
    // relying on a smaller `wm density`.
    await tester.scrollUntilVisibleAndSettle(tile, 200,
        scrollable: find.byType(Scrollable).first);

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('App-open demo'), findsOneWidget);

    final loadButton = find.widgetWithText(FilledButton, 'Force load App Open');
    expect(loadButton, findsOneWidget);

    for (var cycle = 1; cycle <= 2; cycle++) {
      await tester.tap(loadButton);
      expect(await _waitForAppOpenLoaded(tester), isTrue,
          reason: 'cycle $cycle requires a filled test ad');
      for (var i = 0;
          i < 180 &&
              !AdSafetyConfig.canShowFullscreenAdPeek(
                      forType: AdSlotType.appOpen)
                  .canShow;
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
          AdSafetyConfig.canShowFullscreenAdPeek(forType: AdSlotType.appOpen)
              .canShow,
          isTrue,
          reason: 'cycle $cycle must wait for the safety gate, not bypass it');

      var dismissCalls = 0;
      bool? dismissed;
      final show = AdManager().showAppOpenAd(onAdDismiss: (value) {
        dismissCalls++;
        dismissed = value;
      });
      final slot = AdManager().adapter!.appOpenSlot;
      for (var i = 0;
          i < 40 && !(slot.isShowing && slot.displayConfirmed);
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(slot.isShowing && slot.displayConfirmed, isTrue,
          reason: 'cycle $cycle must confirm native display');
      await _waitForNotShowing(tester);
      await show;
      expect(dismissed, isTrue, reason: 'cycle $cycle requires native dismiss');
      expect(dismissCalls, 1);
      expect(slot.isShowing, isFalse);
      expect(tester.takeException(), isNull);
    }
  });
}
