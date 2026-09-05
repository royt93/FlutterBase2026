// On-device integration test for the (pre-existing, NOT round-37-authored)
// COPPA hard-stop mechanism ("R10-B"/"MJ7 round 5 audit",
// `lib/src/core/ad_manager.dart` around `setConsent()`).
//
// Why this file exists: the round-37 audit initially flagged "AppLovin
// doesn't hard-stop when isAgeRestrictedUser flips mid-session" as a MAJOR —
// that turned out to be a false positive (4 independent audit passes missed
// that `AdManager.setConsent()` already hard-stops synchronously and
// re-initialises AppLovin to carry the flag). No code changed here, but the
// mechanism itself never had on-device coverage, and this device is one of
// the few environments known to actually initialise AppLovin successfully
// (real SDK key configured in the example app) rather than the AdMob-only
// path CI is forced onto.
//
// Run with (do NOT pass --dart-define=AD_PROVIDER_ADMOB=true — the whole
// point is the non-AdMob/AppLovin branch):
//   flutter test integration_test/round37_coppa_hardstop_test.dart -d <device-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
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
      'flipping isAgeRestrictedUser to true mid-session hard-stops '
      'AppLovin synchronously, then re-initialises to carry the flag',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    expect(AdManager().isAdMobProvider, isFalse,
        reason: 'this test is specifically about the non-AdMob (AppLovin) '
            'branch — run without --dart-define=AD_PROVIDER_ADMOB=true');
    expect(AdManager().canRequestAds, isTrue,
        reason: 'sanity: ads are allowed before the flag flips');

    await AdManager().setConsent(const AdConsent(isAgeRestrictedUser: true));

    // The hard-stop (`_updateCanRequestAds(false)`) runs synchronously
    // before the re-init is even kicked off, so this must already be false
    // the instant setConsent() returns — no pump needed to observe it.
    expect(AdManager().canRequestAds, isFalse,
        reason: 'the gate must close synchronously the moment the '
            'child-directed flag is set on a non-AdMob provider, before '
            'the re-init that actually carries the flag to AppLovin MAX '
            'even has a chance to run');

    // The re-init (AppLovinAdapter refuses to initialise at all when
    // isAgeRestrictedUser is already true — the T40 init-time gate) runs in
    // the background; wait for it to settle.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(tester.takeException(), isNull,
        reason: 'the re-init this mechanism triggers must not throw');

    // Flip it back — MJ7's own fix for the case this test is really about:
    // the hard-stop must not be a one-way trip.
    await AdManager().setConsent(const AdConsent(isAgeRestrictedUser: false));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (AdManager().canRequestAds) break;
    }
    expect(AdManager().canRequestAds, isTrue,
        reason: 'correcting the flag back to false must recover AppLovin, '
            'not leave it permanently hard-stopped for the rest of the '
            'session (MJ7)');
    expect(tester.takeException(), isNull);
  });
}
