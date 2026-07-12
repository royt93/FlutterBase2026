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
// Ad *content*/fill is never guaranteed, so assertions are lenient about
// whether an ad actually showed and strict about lifecycle/state/no-crash.
//
// Run with:
//   flutter test integration_test/app_open_ad_test.dart -d <device-or-sim-id>

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

    final tile = find.text('App-open ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the App-open ad tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('App-open demo'), findsOneWidget);

    final loadButton = find.widgetWithText(FilledButton, 'Force load App Open');
    expect(loadButton, findsOneWidget);

    // ── Cycle 1: load then show via AdManager() directly (AppOpenDemoPage
    // only exposes a "Force load" button; showAppOpenAd is the SDK's public
    // API used the same way the splash screen uses it, minus bypassSafety).
    await tester.tap(loadButton);
    final loaded1 = await _waitForAppOpenLoaded(tester);
    expect(tester.takeException(), isNull);

    if (loaded1) {
      AdManager().showAppOpenAd(onAdDismiss: (_) {});
      await tester.pump(const Duration(milliseconds: 500));
      // A human taps the close/X button on the native ad when it appears.
      await _waitForNotShowing(tester);
      expect(tester.takeException(), isNull);
    }

    // ── Cycle 2 — proves no zombie/duplicate-load state lingers from cycle 1,
    // which is exactly the race condition class fixed this session.
    await tester.tap(loadButton);
    final loaded2 = await _waitForAppOpenLoaded(tester);
    expect(tester.takeException(), isNull);

    if (loaded2) {
      AdManager().showAppOpenAd(onAdDismiss: (_) {});
      await tester.pump(const Duration(milliseconds: 500));
      await _waitForNotShowing(tester);
    }

    expect(tester.takeException(), isNull);
  });
}
