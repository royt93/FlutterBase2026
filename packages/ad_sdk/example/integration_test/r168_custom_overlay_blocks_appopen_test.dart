// On-device integration test for T168 — a host's own custom overlay (a raw
// `Overlay.insert()`, not a `PopupRoute` pushed through a `Navigator`) must
// block App Open on resume once the host calls
// `markCustomOverlayOnScreen(true)`.
//
// Why on-device: `showAppOpenAdOnResume()` is wired off the real
// `AppLifecycleState.resumed` callback the OS delivers on background →
// foreground. `flutter test` can simulate the callback itself via
// `tester.binding.handleAppLifecycleStateChanged`, exercising the exact same
// code path a real backgrounding does — but the claim under test is that the
// SDK's fullscreen mutex (`_fullscreenBusyReason`) genuinely reaches and gates
// that real resume handler in the compiled app, on a real device, not just in
// a fake-async unit test against an injected fake adapter.
//
// Run with:
//   flutter test integration_test/r168_custom_overlay_blocks_appopen_test.dart \
//     -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _admobConfig() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      autoRequestUmpConsent: false,
      safety: AdSafetyParams(dryRun: true),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    markCustomOverlayOnScreen(false);
    await AdManager().destroy();
  });

  testWidgets(
      'a real background→foreground resume does not clear a host-declared '
      'custom overlay, and the SDK\'s own fullscreen mutex sees it',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CustomOverlayDemoPage()));

    var completed = false;
    await AdManager().initialize(
      config: _admobConfig(),
      onComplete: (_, __) => completed = true,
    );
    expect(completed, isTrue,
        reason: 'sanity: this test needs a real, initialised AdManager so '
            'showAppOpenAdOnResume() runs past its early adapter-null guard '
            'and actually reaches the fullscreen-mutex check this test is '
            'about');
    // This test never runs the example app's own SplashScreen, so
    // _isSplashActive would otherwise stay true forever and
    // showAppOpenAdOnResume() would return on ITS OWN earlier splash guard —
    // never reaching the customOverlayOnScreen check this test is about.
    AdManager().markSplashInactive();

    await tester.tap(find.text('Show custom overlay'));
    await tester.pump();
    expect(customOverlayOnScreen.value, isTrue);
    expect(find.text('Close overlay'), findsOneWidget);

    // A real background → foreground cycle, not a mock adapter.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 500));

    expect(customOverlayOnScreen.value, isTrue,
        reason: 'T168 — a resume must not silently clear the host\'s own '
            'overlay flag');
    expect(AdManager().debugFullscreenBusyReason,
        'a custom host overlay is on screen',
        reason: 'T168 — proves the real resume handler on this device '
            'actually consulted customOverlayOnScreen, not just that the '
            'flag itself is still set');
    // The demo's own overlay card must still be the thing on screen — no
    // App Open (or anything else) got pushed on top of it.
    expect(find.text('Close overlay'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Close overlay'));
    await tester.pump();
    expect(customOverlayOnScreen.value, isFalse);
  });
}
