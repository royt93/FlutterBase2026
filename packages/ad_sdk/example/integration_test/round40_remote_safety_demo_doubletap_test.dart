// Round-40 audit (independent review, IMPORTANT) — a fast double-tap on
// "Apply provider" used to be able to start a second destroy()/initialize()
// before the first one's await resolved. Kept in its own file (like every
// other full-UI `app.main()` integration test in this directory) — two
// `app.main()` mounts in one `flutter test` process is what the framework's
// own `LiveTestWidgetsFlutterBinding` isn't built for, not a bug in this SDK.
//
// Round-40 audit round 2 (independent re-review, R2-02) — the original
// version of this test only asserted the converged end-state ("Provider
// already wired"), which two racing re-inits could equally reach. Now
// asserts `RemoteSafetyDemoPage.debugApplyCallCount == 1` — a real,
// test-only invocation counter incremented past the `_busy` guard — so a
// regression that let the guard race really shows up as 2, not just an
// end-state that happens to look the same either way.
//
// Run with:
//   flutter test integration_test/round40_remote_safety_demo_doubletap_test.dart -d <device-or-sim-id>

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
      'double-tapping "Apply provider" only re-initializes the SDK once',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 4600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Remote safety provider (T88)');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) break;
    }
    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final applyButton = find.text('Apply provider (destroy + re-initialize)');
    // Two taps back-to-back, no pump in between — the second must hit the
    // `_busy` guard synchronously rather than start a second re-init.
    await tester.tap(applyButton);
    await tester.tap(applyButton);
    await _waitForInit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(tester.takeException(), isNull,
        reason: 'a double-tap must never throw or race two re-init cycles');
    expect(find.text('Provider already wired'), findsOneWidget,
        reason: 'must settle into exactly one wired state, not toggle '
            'between two overlapping re-init calls');
    expect(app.RemoteSafetyDemoPage.debugApplyCallCount, 1,
        reason: 'exactly one destroy()/initialize() must have run past the '
            '_busy guard — a real invocation count, not just a converged '
            'end-state two racing calls could equally reach');
  });
}
