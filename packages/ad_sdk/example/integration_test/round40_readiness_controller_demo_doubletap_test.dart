// Round-40 audit (independent review, IMPORTANT) — a fast double-tap on
// "Destroy SDK + replay via controller" used to be able to push two
// `_ReadinessControllerSplash` routes on top of a single destroy(), racing
// two controllers against one SDK instance. Kept in its own file — see
// round40_readiness_controller_demo_test.dart's header for why.
//
// Round-40 audit round 2 (independent re-review, R2-02) — asserts
// `ReadinessControllerDemoPage.debugReplayCallCount == 1`, a real
// test-only invocation counter, instead of only the converged end-state.
//
// Run with:
//   flutter test integration_test/round40_readiness_controller_demo_doubletap_test.dart -d <device-or-sim-id>

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
      'double-tapping "Destroy SDK + replay via controller" only pushes '
      'one splash route', (tester) async {
    tester.view.physicalSize = const Size(1080, 4600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Splash shortcut (T94)');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) break;
    }
    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final replayButton = find.text('Destroy SDK + replay via controller');
    // Two taps back-to-back, no pump in between — the second must hit the
    // `_busy` guard synchronously rather than start a second replay.
    await tester.tap(replayButton);
    await tester.tap(replayButton);

    var poppedBack = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find
          .text('AdReadinessSplashController running...')
          .evaluate()
          .isEmpty) {
        poppedBack = true;
        break;
      }
    }
    expect(poppedBack, isTrue);
    expect(tester.takeException(), isNull,
        reason: 'a double-tap must never throw or leave two splash routes '
            'racing each other');
    expect(find.byType(app.ReadinessControllerDemoPage), findsOneWidget,
        reason: 'must land back on exactly one demo page instance, not a '
            'stack of two pushed splash routes each popping in turn');
    expect(app.ReadinessControllerDemoPage.debugReplayCallCount, 1,
        reason: 'exactly one replay must have run past the _busy guard — a '
            'real invocation count, not just a converged end-state two '
            'racing calls could equally reach');
  });
}
