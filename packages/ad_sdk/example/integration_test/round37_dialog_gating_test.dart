// On-device integration test for round-37 audit — two fixes around
// `AdScreenRouteLogger.isDialogOnTop`:
//
//   1. `canShowInterstitial()`/`canShowRewardedAd()`/
//      `canShowRewardedInterstitialAd()` now also refuse while a dialog/
//      popup is on top (not just while `AdLoadingDialog` is showing) — the
//      double-tap-stacks-two-disclosure-dialogs bug.
//   2. `AdManager().destroy()` no longer force-resets `isDialogOnTop` to
//      false, since it doesn't actually dismiss a real dialog still on
//      screen.
//
// Why on-device: `test/ad_manager_core_test.dart`'s two "round-37 audit"
// groups already prove both mechanisms against a manually-driven
// `AdScreenRouteLogger` instance, not the app's real, registered one. This
// drives the SAME assertions through the REAL example app's own
// `navigatorObservers: [adRouteObserver, AdScreenRouteLogger()]` wiring (see
// `example/lib/main.dart`) — proving the real, shipped integration contract
// reacts correctly, not just the class in isolation.
//
// This does not attempt to race two real button taps against the exact
// dialog-open timing window (that would be flaky without proving anything
// the deterministic unit test doesn't already prove) — it drives a real
// dialog through the real Navigator instead and checks the real gate.
//
// Run with:
//   flutter test integration_test/round37_dialog_gating_test.dart -d <device-or-sim-id>

// The navigator's root context is long-lived for this whole test (it is
// the app's own root, never disposed mid-test), so using it after an
// `await` here is safe — same reasoning `us_privacy_propagation_test.dart`
// and others rely on implicitly by never triggering this lint in the
// first place.
// ignore_for_file: use_build_context_synchronously

import 'dart:async';

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
      'canShowInterstitial()/canShowRewardedAd()/'
      'canShowRewardedInterstitialAd() all go false while a real dialog is '
      'on top of the real app Navigator, and the dialog-specific gate '
      '(isDialogOnTop) clears again once it is popped',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // canShowRewardedAd() deliberately returns true unconditionally for an
    // active VIP member (the watch-ad-to-extend button quirk — see its own
    // doc comment), before it ever reaches the isDialogOnTop check this
    // test is about. A fresh install auto-grants a first-install VIP grace
    // window, which is exactly the state this real device was in on first
    // run of this file. Revoke it so this test actually exercises the
    // normal (non-VIP) gating path.
    await AdManager().vip?.revokeAll();

    expect(AdScreenRouteLogger.isDialogOnTop, isFalse,
        reason: 'sanity: nothing has pushed a dialog yet');

    final navigatorKey = AdManager().navigatorKey;
    final context = navigatorKey?.currentContext;
    expect(context, isNotNull,
        reason: 'the real app must have a live navigator context to push a '
            'real dialog into');

    // Push a real dialog through the real app Navigator — the same
    // `AdScreenRouteLogger` instance wired into the real app's
    // `navigatorObservers` sees this, not a test-only stand-in.
    unawaited(showDialog<void>(
      context: context!,
      builder: (_) => const AlertDialog(title: Text('round-37 probe dialog')),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('round-37 probe dialog'), findsOneWidget,
        reason: 'sanity: the real dialog is actually on screen');
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue,
        reason: 'the real, app-registered AdScreenRouteLogger must see the '
            'real dialog');

    expect(AdManager().canShowInterstitial(), isFalse,
        reason: 'a real dialog on screen must block a fullscreen ad from '
            'being allowed to show on top of it');
    expect(AdManager().canShowRewardedAd(), isFalse);
    expect(AdManager().canShowRewardedInterstitialAd(), isFalse);

    // Independent review (round 37 verification, Nitpick) — an earlier
    // version of this test asserted the three canShow*() calls flip back to
    // true here too, but they compound several OTHER real gates besides
    // isDialogOnTop (ad-readiness, the safety-cooldown peek, VIP) that a
    // fresh app launch on a real device has no guaranteed state for — that
    // assertion failed on-device for "no interstitial loaded yet", nothing
    // to do with the dialog gate this test is actually about. The
    // deterministic "false while a dialog is up, true again once it's
    // popped, with a ready ad" case is already proven with full control
    // over ad state in `test/ad_manager_core_test.dart`'s fake-adapter
    // unit tests. This integration test's job is only to prove the real,
    // app-registered `AdScreenRouteLogger` correctly reflects a real
    // Navigator pop — which is exactly `isDialogOnTop`.
    Navigator.of(context).pop();
    await tester.pump(const Duration(milliseconds: 300));
    expect(AdScreenRouteLogger.isDialogOnTop, isFalse,
        reason: 'popping the real dialog must clear the flag on its own');

    // round-37 audit — destroy() must NOT force isDialogOnTop back to false:
    // it does not actually dismiss a real dialog still on screen. Push a
    // second dialog to re-create that state, since the first was just
    // popped above.
    unawaited(showDialog<void>(
      context: context,
      builder: (_) =>
          const AlertDialog(title: Text('round-37 probe dialog #2')),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue,
        reason: 'sanity: the second real dialog is up');

    await AdManager().destroy();
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue,
        reason: 'destroy() does not dismiss a real dialog still on screen '
            '— the flag must keep reflecting that, or an App Open ad on '
            'the next resume could stack right on top of it');

    Navigator.of(context).pop();
    await tester.pump(const Duration(milliseconds: 300));
    expect(AdScreenRouteLogger.isDialogOnTop, isFalse,
        reason: 'popping the real dialog must clear the flag on its own, '
            'independent of destroy()');
  });
}
