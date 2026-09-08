// T147 — RemoteSafetyDemoPage's per-format kill switch toggles (rewarded vs
// rewardedInterstitial) really reach the live AdSafetyConfig, and gate the
// CORRECT format — the bug this task fixed had canShowRewardedAd() checking
// rewardedInterstitial's kill switch instead of its own. Same
// destroy()+initialize()+refreshRemoteSafetyParams() wiring proof pattern as
// round40_remote_safety_demo_test.dart, but for the T147 fix specifically.
//
// Run with:
//   flutter test integration_test/remote_safety_demo_format_kill_switch_test.dart -d <device-or-sim-id>

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
      'disabling ONLY "rewarded" via the demo\'s kill switch gates the '
      'rewarded peek but leaves rewardedInterstitial untouched', (tester) async {
    tester.view.physicalSize = const Size(1080, 4600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Remote safety provider (T88)');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue);

    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('Apply provider (destroy + re-initialize)'));
    await _waitForInit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('Provider already wired'), findsOneWidget);

    expect(
        AdSafetyConfig.canShowFullscreenAdPeek(forType: AdSlotType.rewarded)
            .canShow,
        isTrue,
        reason: 'sanity: nothing disabled yet');
    expect(
        AdSafetyConfig.canShowFullscreenAdPeek(
                forType: AdSlotType.rewardedInterstitial)
            .canShow,
        isTrue,
        reason: 'sanity: nothing disabled yet');

    await tester.tap(find.text('Disable rewarded'));
    await tester.pump();
    await tester.tap(find.text('Push update (refreshRemoteSafetyParams)'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);

    expect(
        AdSafetyConfig.canShowFullscreenAdPeek(forType: AdSlotType.rewarded)
            .canShow,
        isFalse,
        reason: 'the kill switch just pushed must gate the rewarded peek');
    expect(
        AdSafetyConfig.canShowFullscreenAdPeek(
                forType: AdSlotType.rewardedInterstitial)
            .canShow,
        isTrue,
        reason: 'T147 — disabling rewarded must NOT also gate '
            'rewardedInterstitial; that was the exact bug');
  });
}
