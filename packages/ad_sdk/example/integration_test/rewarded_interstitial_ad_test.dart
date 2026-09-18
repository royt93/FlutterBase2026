// On-device integration test for the Rewarded interstitial demo
// (RewardedInterstitialDemoPage).
//
// Round-27 audit — showRewardedInterstitialAd() had zero example-app test
// coverage at any level (unit, widget, or on-device) despite being a fully
// supported ad surface. This closes the on-device gap.
//
// Unlike rewarded_ad_test.dart (which drives a real show+dismiss cycle and
// needs a human to manually tap the ad's close button — see that file's own
// note on why), this test stays in the no-human-interaction lane, matching
// fill_rate_monitor_demo_test.dart / monetization_arbitrator_demo_test.dart:
// it asserts navigation, real-adapter wiring, and that tapping "Watch"
// before the ad has actually finished loading resolves safely to
// (shown: false, earned: false) with no exception and no coin granted —
// never that a real ad was shown, since fill/timing on a fresh simulator
// launch is not guaranteed.
//
// Run with:
//   flutter test integration_test/rewarded_interstitial_ad_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scroll_helpers.dart';

// Same budget/reasoning as fill_rate_monitor_demo_test.dart /
// rewarded_ad_test.dart — real ATT + UMP prompts can each eat up to ~20s.
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

/// Same reasoning as rewarded_ad_test.dart's helper of the same name — a
/// fresh install's first-install VIP grace silently no-ops every load/show
/// call, which would make this test trivially pass without exercising
/// anything real.
///
/// Round 44 — used to also dismiss the SDK's built-in post-splash consent
/// dialog if `revokeAll()` unmasked it mid-test; that dialog was removed
/// (round-44 audit finding 1), so this is just the VIP-grace revoke now.
Future<void> _revokeVipGrace(WidgetTester tester) async {
  await AdManager().vip!.revokeAll();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'navigates to the demo, real adapter is wired, and tapping Watch '
      'before load finishes resolves safely with no coin granted',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);
    await _revokeVipGrace(tester);

    // Wait for the Splash → Home navigation to actually land before touching
    // any HomePage finder — scrollUntilVisible needs a real Scrollable to
    // already exist in the tree, and there is none while Splash is still up.
    // "Banner ad" is the first tile in the list, so it's always built
    // regardless of scroll position — a reliable "we're on Home" signal.
    var onHome = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('Banner ad').evaluate().isNotEmpty) {
        onHome = true;
        break;
      }
    }
    expect(onHome, isTrue, reason: 'must navigate to HomePage after init');

    // HomePage's 19-tile ListView virtualizes off-screen children (a plain
    // ListView(children:) still goes through SliverList, so a tile past the
    // initial viewport + cache extent is never mounted) — this tile sits one
    // position below the pre-existing "Rewarded ad" tile, which is why a
    // fixed-time poll (the pattern every OTHER home-tile test uses, because
    // their tiles happen to fit the default viewport) isn't enough here.
    // scrollUntilVisibleAndSettle drags the list until the tile is actually
    // built, not just waits.
    final tile = find.text('Rewarded interstitial ad');
    await tester.scrollUntilVisibleAndSettle(tile, 200,
        scrollable: find.byType(Scrollable).first);
    expect(tile, findsOneWidget,
        reason: 'HomePage must list the Rewarded interstitial ad tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Rewarded interstitial demo'), findsOneWidget);

    // Real adapter/manager wiring, not a fake — same check style as
    // fill_rate_monitor_demo_test.dart's `monitor` assertion.
    expect(AdManager().adapter, isNotNull,
        reason: 'a real provider adapter must be live post-init');

    expect(find.text('Coins: 0'), findsOneWidget);
    expect(find.textContaining('Last: —'), findsOneWidget);

    final showButton = find.widgetWithText(
        FilledButton, 'Watch rewarded interstitial for +10 coins');
    await tester.scrollUntilVisibleAndSettle(showButton, 200,
        scrollable: find.byType(Scrollable).first);
    expect(showButton, findsOneWidget);

    // Tap immediately, before any background load has had time to finish —
    // canShowRewardedInterstitialAd() must gate this safely rather than
    // crash or grant a reward for an ad that was never shown.
    await tester.tap(showButton);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.takeException(), isNull);
    expect(find.text('Coins: 0'), findsOneWidget,
        reason: 'no coin may be granted unless the ad was actually shown '
            'and earned');
  });
}
