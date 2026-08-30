// On-device integration test for round-13 QC round 11 (MAJOR) — a native UMP
// consent form still on screen must keep fullscreen ads blocked across
// `AdManager.destroy()` and the next `initialize()`.
//
// Why it exists: `destroy()` used to clear the module-level form counter,
// reasoning that it had just torn the adapter down so nothing could be drawn
// over anything. But destroy() does NOT dismiss the native form — the same
// fact the consent session epoch exists for — and the next initialize() brings
// a fresh adapter. A form the user is still reading then had no ad block, and
// an ad drawn over a consent form is a policy violation on its own (the tap
// the consent choice needs lands on the ad instead).
//
// Why on-device: the block has to survive a real destroy()/initialize() cycle
// against the real platform channels, timers and plugin registrations — the
// place a module-level counter and a real Timer actually live.
//
// Unit coverage of the same contract: test/privacy_options_test.dart
// ("a form still on screen keeps the mutex across destroy() ...").
//
// Run with:
//   flutter test integration_test/ump_form_block_destroy_test.dart -d <device>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ump_consent.dart'
    show
        debugUmpFormBackstopOverride,
        markUmpFormOnScreen,
        resetUmpFormOnScreen;
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
      safety: AdSafetyParams(dryRun: true),
      // The SDK's own UMP flow is switched off here on purpose. This test owns
      // the form-on-screen counter (`markUmpFormOnScreen`) and asserts it
      // drops back to zero on `release()`; with the automatic flow on, a device
      // that answers `status: required` — every iOS Simulator, which can never
      // present the form at all ("9:The provided view controller is already
      // presenting another view controller") — takes a second count of its own
      // inside `requestUmpConsentFlow`, so `release()` leaves the mutex held by
      // the SDK's still-outstanding form and the assertion reads as a
      // regression it is not. What is under test is the counter surviving
      // destroy()/initialize(), not UMP.
      autoRequestUmpConsent: false,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    resetUmpFormOnScreen();
    debugUmpFormBackstopOverride = null;
    await AdManager().destroy();
  });

  testWidgets(
      'a consent form on screen keeps fullscreen ads blocked across '
      'destroy() and the next session', (tester) async {
    await AdManager().initialize(config: _admobConfig(), onComplete: (_, __) {});

    // A form is presented and its dismiss callback has not arrived yet.
    final release = markUmpFormOnScreen();
    expect(AdManager().fullscreenBusy.value, isTrue,
        reason: 'sanity: a form on screen holds the fullscreen mutex');

    await AdManager().destroy();
    expect(AdManager().fullscreenBusy.value, isTrue,
        reason: 'destroy() does not dismiss the native form, so the block it '
            'earned must survive the teardown');

    // The host re-initialises — a fresh adapter, with the same form still up.
    await AdManager().initialize(config: _admobConfig(), onComplete: (_, __) {});
    expect(AdManager().fullscreenBusy.value, isTrue,
        reason: 'now there IS an ad that could be drawn over the form: an App '
            'Open ad here would steal the tap the consent choice needs');
    expect(AdManager().debugFullscreenBusyReason, 'a consent form is on screen');

    release();
    expect(AdManager().fullscreenBusy.value, isFalse,
        reason: 'the user answered the form — ads are free again');
  });

  testWidgets('a dismiss callback that never arrives still releases via its '
      'backstop', (tester) async {
    // The other half. Not clearing the counter in destroy() must not be able
    // to block fullscreen ads forever: every presentation owns a backstop
    // (15 minutes in production), and that is what bounds a leak now.
    debugUmpFormBackstopOverride = const Duration(seconds: 2);
    await AdManager().initialize(config: _admobConfig(), onComplete: (_, __) {});
    markUmpFormOnScreen();
    await AdManager().destroy();
    expect(AdManager().fullscreenBusy.value, isTrue);

    await AdManager().initialize(config: _admobConfig(), onComplete: (_, __) {});
    var released = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!AdManager().fullscreenBusy.value) {
        released = true;
        break;
      }
    }
    expect(released, isTrue,
        reason: 'a form that never reports a dismiss must not cost the next '
            'session its fullscreen ads for the whole process');
  });
}
