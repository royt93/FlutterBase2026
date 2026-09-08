// On-device integration test for ConsentDemoPage's "Simulate broken privacy
// store" button (T146) — proves IabStorage.usPrivacyOptedOut() fails CLOSED
// (returns true) when the platform preference store throws on every read,
// instead of returning null (which every real caller treats as "no signal",
// i.e. NOT an opt-out). See test/us_privacy_fail_closed_test.dart in the SDK
// package for the unit-level proof of the same contract; this file proves
// the demo button wired to it on a real device does the same thing.
//
// Run with:
//   flutter test integration_test/consent_privacy_storage_fail_closed_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scroll_helpers.dart';

// Same rationale/budget as consent_country_demo_test.dart's _waitForInit —
// real ATT + real UMP form can each eat up to ~20s before initialize()
// even starts resolving on a real device.
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'simulating a broken privacy store on the Consent demo page shows the '
      'fail-closed result, not a bug', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Consent / GDPR');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list Consent / GDPR tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Consent demo'), findsOneWidget);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();

    final button = find.text('Simulate broken privacy store');
    await tester.scrollUntilVisibleAndSettle(button, 300,
        scrollable: find.byType(Scrollable).first);

    await tester.tap(button);
    // The demo's async work (swap platform instance, read, restore) needs a
    // real event-loop turn, not just fake-async pumps.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final resultText = find.textContaining('usPrivacyOptedOut() →');
    await tester.scrollUntilVisibleAndSettle(resultText, 300,
        scrollable: find.byType(Scrollable).first);

    expect(
        find.textContaining(
            'usPrivacyOptedOut() → ✅ true (fail-closed — treated as opted-out)'),
        findsOneWidget,
        reason: 'a store that throws on every read must fail closed (true), '
            'never null — see T146. If this reads "BUG" instead, the fix '
            'regressed.');
  });
}
