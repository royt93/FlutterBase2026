// On-device integration test — a REAL App Open ad, on the REAL AppLovin MAX
// SDK, shown over a REAL live banner.
//
// Rounds 27-35 of this SDK's review history found and fixed five straight
// regressions in exactly this mechanism (`InlineVisibilityOwners` /
// `_inlineRefresh` / `_fullscreenOverInline`) — every one of them proven only
// against a fake `AppLovinBridge` and a unit/widget-test harness, because the
// CI Android job forces `AD_PROVIDER_ADMOB` (no AppLovin SDK key is normally
// committed) and no existing on-device suite exercises the AppLovin path at
// all. This file runs with a REAL key + REAL MAX ad unit ids passed via
// `--dart-define`, so it is the first on-device proof that the mechanism
// those five rounds rebuilt actually holds against the real native SDK.
//
// It does NOT wait for a human to dismiss the ad — a real App Open, once
// filled, can only be dismissed by a person tapping its close button, and this
// environment has no automated way to do that safely (tapping the wrong
// pixel on a real ad risks counting as an accidental click). Instead it
// asserts the moment that actually matters: the instant the App Open slot
// reports `showing`, the live banner underneath it must already be held down
// — real AppLovin auto-refresh disabled, on the real inline surface. The test
// ends there; nothing on the ad itself is tapped.
//
// Run with (all five --dart-define values required — see CLAUDE.md/scratchpad
// for the recovered real credentials; NEVER commit them):
//   flutter test integration_test/r36_real_applovin_appopen_over_banner_test.dart \
//     -d <device-id> --dart-define=APPLOVIN_SDK_KEY=... (+4 more, see main.dart)

import 'dart:async';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
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
      'a real App Open holds down a real live AppLovin banner\'s auto-refresh',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    expect(AdManager().isAdMobProvider, isFalse,
        reason: 'sanity — this test is only meaningful on the AppLovin path; '
            'run it WITHOUT --dart-define=AD_PROVIDER_ADMOB=true');

    await AdManager().vip!.revokeAll();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      final allow = find.text('Allow personalized ads');
      if (allow.evaluate().isNotEmpty) {
        await tester.tap(allow);
        await tester.pump(const Duration(milliseconds: 300));
        break;
      }
    }

    // Get to the real Banner demo page — mounts a real BannerAdWidget over
    // the real AppLovinAdapter, exactly the round-27..35 widget path.
    final tile = find.text('Banner ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list the Banner ad tile');
    await tester.tap(tile);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // BannerDemoPage deliberately mounts TWO instances (T65 keyed-by-instance
    // proof) — the first one is enough to hold down for this assertion.
    expect(find.byType(BannerAdWidget), findsNWidgets(2));

    final adapter = AdManager().adapter;
    expect(adapter, isA<AppLovinAdapter>(),
        reason: 'sanity — the real AppLovin adapter must be installed');
    final al = adapter! as AppLovinAdapter;
    final bannerKey = tester.state(find.byType(BannerAdWidget).first);
    final listenables = al.banner(bannerKey);

    // Give the real banner a window to actually fill before judging it.
    var bannerFilled = false;
    for (var i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (listenables.isLoaded.value) {
        bannerFilled = true;
        break;
      }
    }
    if (!bannerFilled) {
      // Ad *fill* is never guaranteed on every run/network — the mechanism
      // under test only matters once a real ad view exists to hold down.
      // Round-39 QC (reviewer A) — a bare `return` here reported a green run
      // that never reached the one assertion this file exists for. A skip
      // that reads as a pass is worse than no test.
      markTestSkipped(
          'real banner did not fill within 90s — cannot assert the hold '
          'without a live ad view. Not a failure of the SDK.');
      return;
    }

    // Force-load and show a REAL App Open, the same public API the splash
    // screen uses (minus bypassSafety, since VIP is already revoked above).
    await AdManager().adapter!.loadAppOpen(onAdLoaded: (_) {});
    var loaded = false;
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final slot = AdManager().adapter?.appOpenSlot;
      if (slot != null && slot.isReady) {
        loaded = true;
        break;
      }
    }
    if (!loaded) {
      markTestSkipped(
          'real App Open did not fill within 40s. Not a failure of the SDK.');
      return;
    }

    unawaited(AdManager().showAppOpenAd(onAdDismiss: (_) {}));

    var showing = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      final slot = AdManager().adapter?.appOpenSlot;
      if (slot != null && slot.isShowing) {
        showing = true;
        break;
      }
    }
    expect(showing, isTrue,
        reason: 'sanity — a loaded App Open must actually start showing');

    // THE assertion. No tap, no dismiss — judged the instant it is showing.
    expect(listenables.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding rounds 27-35 fixed and this test finally proves '
            'on the real native SDK — a real MAX banner must not keep '
            'auto-refreshing (buying invisible impressions) underneath a '
            'real App Open that is genuinely on screen');

    // Deliberately not waiting for a human to dismiss it. The test ends with
    // the ad still showing; the app process is torn down by the harness.
  });
}
