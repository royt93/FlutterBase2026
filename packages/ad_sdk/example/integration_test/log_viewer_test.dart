// On-device integration test for the Log viewer demo (LogViewerDemoPage).
//
// The ring buffer's real data source is `LogBuffer.instance`
// (example/lib/main.dart §2), wired as `AdConfig.onLog` — SDK init alone
// (verbose logLevel, see DemoConfig.build()) generates plenty of entries
// before this page is ever opened, so no extra ad interaction is needed to
// populate it. This test asserts the viewer shows real entries and that the
// clear button empties it.
//
// Run with:
//   flutter test integration_test/log_viewer_test.dart -d <device-or-sim-id>

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

  testWidgets('Log viewer shows entries accumulated from real SDK init logs',
      (tester) async {
    // HomePage's demo list is a viewport-lazy ListView — "Log viewer" is the
    // 8th of 10 tiles and isn't built at all at default phone height (see
    // compliance_export_test.dart for the same issue on the last tile). Use a
    // tall synthetic viewport so every tile is within the build/cache extent
    // instead of requiring a real scroll gesture.
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Log viewer');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list the Log viewer tile');

    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Log viewer'), findsWidgets);

    // Verbose log level during SDK init guarantees non-empty entries by now.
    expect(find.text('(no logs yet)'), findsNothing);

    // Clear button empties the ring buffer live.
    await tester.tap(find.byIcon(Icons.delete));
    await tester.pump();
    expect(find.text('(no logs yet)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
