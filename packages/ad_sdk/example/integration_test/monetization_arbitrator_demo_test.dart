// On-device integration test for the Smart Monetization Arbitrator demo
// control, which lives on the Safety status page (SafetyDemoPage) alongside
// the Fill-Rate Monitor control (see fill_rate_monitor_demo_test.dart for
// that one) — distinct from safety_status_test.dart, which only asserts the
// page's *display* of the fixed kDemoSafetyParams and never touches either
// opt-in button.
//
// Tapping "Enable Smart Arbitrator" calls the real
// `AdManager().enableArbitrator(MonetizationArbitrator(...))` and the demo
// then reads `AdManager().arbitrator` back to render its stats line — this
// test asserts that real object round-trip, not just local widget state.
//
// Run with:
//   flutter test integration_test/monetization_arbitrator_demo_test.dart -d <device-or-sim-id>

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Enable Smart Arbitrator button wires a real MonetizationArbitrator into AdManager()',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Safety status');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Safety status tile');

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Safety demo'), findsOneWidget);

    // Starts disabled unless a prior test in this run already enabled it —
    // AdManager().arbitrator is a process-lifetime singleton, so tolerate
    // either starting state but always assert the post-tap state is wired.
    final enableButton = find.widgetWithText(
        FilledButton, 'Enable Smart Arbitrator (per-slot + guardrail)');
    await tester.scrollUntilVisible(enableButton, 200,
        scrollable: find.byType(Scrollable).first);

    if (AdManager().arbitrator == null) {
      await tester.tap(enableButton);
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Real object now live on AdManager(), not just local widget state.
    final arbitrator = AdManager().arbitrator;
    expect(arbitrator, isNotNull,
        reason:
            'enableArbitrator() must install a real MonetizationArbitrator');

    // The demo's stats line reads straight from that same object.
    expect(find.textContaining('estimatedEcpm='), findsOneWidget);
    expect(find.textContaining('vetoRate='), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
