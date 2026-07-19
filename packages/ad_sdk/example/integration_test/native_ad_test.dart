// On-device integration test for the Native ad demo (NativeDemoPage).
//
// Unlike Banner/MREC, native ads have no auto-refresh and no route-pause
// wiring (see the demo's own explanatory text) — it's a single fixed-layout
// slot. So this test just navigates to it and asserts the page renders and
// survives without crashing while the native ad attempts to load.
//
// Ad *content*/fill is never guaranteed (especially on a simulator), so this
// only asserts the demo page renders — not that a specific creative loaded.
//
// Run with:
//   flutter test integration_test/native_ad_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
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

  testWidgets('Native ad demo renders without crashing', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Native ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list the Native ad tile');

    await tester.tap(tile);
    // No auto-refresh timer to avoid here, but keep the same bounded-window
    // convention as the other ad-slot demo tests for a real network load.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.text('Native demo'), findsOneWidget);
    expect(find.textContaining('Native ad v1: fixed layout'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
