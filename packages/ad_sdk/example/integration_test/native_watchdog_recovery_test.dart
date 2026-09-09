// T152 — on-device proof that a native ad watchdog timeout gets a proper
// error state (hasError) and self-heals on the next onAppResumed(), same
// as banner/mrec already did. Fires the watchdog immediately via the SDK's
// own debug seam (AdSlot.debugFireLoadWatchdogNow()) instead of waiting out
// the real 30s or a native ad unit that would return a fast, real no-fill
// error rather than genuine silence — see NativeDemoPage's own comment for
// why a native SDK can't be made to reproduce true silence on demand.
//
// Run with:
//   flutter test integration_test/native_watchdog_recovery_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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
      'native watchdog timeout gets hasError and self-heals on '
      'onAppResumed()', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Native ad');
    var foundTile = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list Native ad tile (a real splash App Open '
            'ad may be covering it and take a while to auto-dismiss)');

    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final button = find.text('Simulate watchdog timeout');
    await tester.scrollUntilVisible(button, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('hasError=true'), findsOneWidget,
        reason: 'T152 — the watchdog must set hasError, not leave the '
            'widget stuck with no error state');

    final resumeButton = find.text('Simulate app resume');
    await tester.scrollUntilVisible(resumeButton, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(resumeButton);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('hasError=false'), findsOneWidget);
    expect(find.textContaining('isLoading=true'), findsOneWidget,
        reason: 'T152 — onAppResumed() must actually fire a new native '
            'request, not just clear the display-only hasError flag '
            '(an independent codex re-review caught the first version of '
            'this test asserting only the latter, a false positive if the '
            'retry were refused by the failure backoff)');
  });
}
