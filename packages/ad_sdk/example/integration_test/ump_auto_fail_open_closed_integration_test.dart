// On-device integration test for Issue 1 — initialize()'s autoRequestUmpConsent
// branch must fail OPEN only for MissingPluginException and fail CLOSED for
// any other exception. See ump_auto_fail_open_closed_test.dart (unit) and
// ump_auto_fail_open_closed_widget_test.dart (widget) for the same contract
// proven against mocked method channels inside `flutter test`.
//
// Deviates from this suite's usual app.main() pattern on purpose: the example
// app's DemoConfig never sets autoRequestUmpConsent (its splash calls
// requestUmpConsent() itself instead — see main.dart's splash initState), so
// driving the real app would never reach the branch under test at all. This
// drives AdManager().initialize() directly with a config that opts in, the
// same way the widget test does — but running on a real device with the real
// AdMob plugin channel registered (unlike plain `flutter test`, where the
// AppLovin provider is used instead because AdMobAdapter.initialize() cannot
// complete against a mocked channel). debugForceAutoUmpError still forces the
// exact exception under test — on a real device with the channel actually
// wired, requestConsentInfoUpdate would never throw MissingPluginException
// naturally, so the seam is required either way.
//
// Run with:
//   flutter test integration_test/ump_auto_fail_open_closed_integration_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
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
      autoRequestUmpConsent: true,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AdManager().debugForceAutoUmpError = null;
    await AdManager().destroy();
  });

  testWidgets(
      'MissingPluginException fails OPEN on a real device with the real '
      'AdMob channel wired', (tester) async {
    AdManager().debugForceAutoUmpError =
        MissingPluginException('forced for test');

    await AdManager().initialize(
      config: _admobConfig(),
      onComplete: (_, __) {},
    );

    var opened = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (AdManager().canRequestAds) {
        opened = true;
        break;
      }
    }

    expect(opened, isTrue,
        reason: 'UMP not wired (forced via debugForceAutoUmpError) must '
            'fail OPEN on a real device too, not only against a mocked '
            'method channel');
    expect(AdManager().debugUmpAttemptFailed, isTrue);
  });

  testWidgets(
      'a non-MissingPluginException fails CLOSED on a real device with the '
      'real AdMob channel wired', (tester) async {
    AdManager().debugForceAutoUmpError = Exception('forced network failure');

    await AdManager().initialize(
      config: _admobConfig(),
      onComplete: (_, __) {},
    );

    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(AdManager().canRequestAds, isFalse,
        reason: 'a genuine consent-fetch failure must keep the gate closed '
            'on a real device too — failing open here would ship ads with '
            'no verified consent decision');
    expect(AdManager().debugUmpAttemptFailed, isTrue);
  });
}
