// Round-40 audit round 2 (independent re-review, R2-03) — "Restore demo
// defaults" was added to fix R2's MINOR finding (the remote-safety demo
// mutated the app's live AdSafetyConfig with no way back), but was never
// itself proven on a real device. Confirms it actually detaches the
// provider and puts the live AdSafetyConfig back on `DemoConfig.instance
// .build().safety`'s own value — not just that the button doesn't crash.
//
// Run with:
//   flutter test integration_test/round40_remote_safety_demo_restore_test.dart -d <device-or-sim-id>

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
      '"Restore demo defaults" detaches the provider and puts '
      'AdSafetyConfig back on DemoConfig\'s own default', (tester) async {
    tester.view.physicalSize = const Size(1080, 4600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final defaultMaxPerDay =
        app.DemoConfig.instance.build().safety.maxFullscreenAdsPerDay;

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

    // Wire the provider and push a value that must NOT survive restore.
    await tester.tap(find.text('Apply provider (destroy + re-initialize)'));
    await _waitForInit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.drag(find.byType(Slider), const Offset(2000, 0));
    await tester.pump();
    await tester.tap(find.text('Push update (refreshRemoteSafetyParams)'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 50,
        reason: 'sanity: the mutation this test restores away must have '
            'actually landed first');

    await tester.tap(
        find.text('Restore demo defaults (destroy + re-initialize)'));
    await _waitForInit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(tester.takeException(), isNull,
        reason: 'Restore demo defaults must not throw');
    expect(find.text('Apply provider (destroy + re-initialize)'),
        findsOneWidget,
        reason: 'the button must go back to its unwired label — the '
            'provider is detached, not just its UI value reset');
    expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay,
        defaultMaxPerDay,
        reason: 'the live AdSafetyConfig must actually be back on '
            'DemoConfig\'s own default, not still holding the pushed '
            'remote value');
  });
}
