// On-device integration test for the Diagnostics & self-check demo
// (DiagnosticsDemoPage, main.dart §18) — the highest-priority page per T45
// since it aggregates several subsystems (mediation waterfall, fill rate,
// arbitrator stats, consent, per-slot load) into one screen and is therefore
// the most likely to silently regress.
//
// Exercises both real API calls the page wires up:
//   - `AdManager().diagnostics()` (synchronous, JSON-rendered immediately).
//   - `AdManager().runIntegrationSelfCheck()` (async — walks init → consent →
//     per-slot load on-device, so it needs the same generous real-network
//     polling window the other ad-load tests use, not a fixed short pump).
//
// Ad *content*/fill for the self-check's per-slot load items is never
// guaranteed, so this asserts the self-check actually RAN and rendered a
// result (pass or fail per item), not that every item came back "pass".
//
// Run with:
//   flutter test integration_test/diagnostics_demo_test.dart -d <device-or-sim-id>

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

// Self-check drives real per-slot ad loads over the network before
// resolving — same rationale as vip_api_playground_test.dart's _pumpUntil:
// don't guess a fixed pump duration covers a real platform/network
// round-trip, poll for the resulting UI condition instead.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 120,
  Duration step = const Duration(milliseconds: 500),
}) async {
  for (var i = 0; i < attempts; i++) {
    if (condition()) return;
    await tester.pump(step);
  }
  expect(condition(), isTrue,
      reason:
          'condition did not become true within ${attempts * step.inMilliseconds}ms');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'diagnostics() renders a JSON snapshot and runIntegrationSelfCheck() renders per-item results',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Diagnostics & self-check');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Diagnostics & self-check tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    // HomePage's tile label and this page's AppBar title are the same
    // string, and MaterialPageRoute keeps HomePage mounted (offstage)
    // beneath the new route — so this matches 2, not 1.
    expect(find.text('Diagnostics & self-check'), findsWidgets);

    // Run diagnostics() — synchronous, real AdManager().diagnostics() JSON.
    // Tapping the label text directly (rather than
    // find.widgetWithText(FilledButton, ...)) — `FilledButton.icon` builds a
    // private `_FilledButtonWithIcon` subclass, and `find.byType` matches by
    // exact runtimeType, not `is`, so it never matches a plain FilledButton
    // finder for icon-labelled buttons.
    final diagButton = find.text('Run diagnostics()');
    await tester.scrollUntilVisible(diagButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(diagButton);
    await tester.pump(const Duration(milliseconds: 300));

    final expectedDiag = AdManager().diagnostics().toJson().keys.first;
    expect(find.textContaining(expectedDiag), findsOneWidget,
        reason: 'diagnostics() JSON card must render real diagnostics keys');
    expect(tester.takeException(), isNull);

    // Run runIntegrationSelfCheck() — async, walks init/consent/per-slot
    // load for real on-device. Give it the same generous window the other
    // ad-load tests use.
    final selfCheckButton = find.text('Run runIntegrationSelfCheck()');
    await tester.scrollUntilVisible(selfCheckButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(selfCheckButton);
    await tester.pump();

    // Button shows a spinner while running (icon swapped for
    // CircularProgressIndicator) — assert it appears, confirming the async
    // call actually started rather than completing synchronously/no-op.
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    final resultCard = find.textContaining('All checks passed');
    final failedCard = find.text('FAILED');
    await _pumpUntil(
        tester,
        () =>
            resultCard.evaluate().isNotEmpty ||
            failedCard.evaluate().isNotEmpty);

    // Either outcome is acceptable — real per-slot ad fill isn't guaranteed
    // on this run — but the result card (with per-item ListTiles) must have
    // rendered, proving the self-check actually executed and reported back.
    expect(resultCard.evaluate().isNotEmpty || failedCard.evaluate().isNotEmpty,
        isTrue,
        reason: 'self-check must render either a pass or fail result card');
    expect(find.byType(ListTile), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
