// T151 — on-device proof that a corrupted compliance-log entry does not
// crash the Diagnostics & self-check demo page.
//
// Run with:
//   flutter test integration_test/diagnostics_corrupted_entry_crash_guard_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Simulate corrupted log entry does not crash the real app',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();

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
        reason: 'HomePage must list Diagnostics & self-check tile');

    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final button = find.text('Simulate corrupted log entry (T151)');
    await tester.scrollUntilVisible(button, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(button);
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'a corrupted slotType entry must not crash the app — '
            'T151');
    expect(find.textContaining('did NOT throw'), findsOneWidget);
  });
}
