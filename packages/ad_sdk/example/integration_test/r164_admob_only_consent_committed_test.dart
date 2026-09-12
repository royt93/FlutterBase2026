// On-device integration test for T164 — an AdMob-only app (AdConfig.provider:
// AdProvider.admob, the example app's own default under
// --dart-define=AD_PROVIDER_ADMOB=true) must actually get
// `lastConsentAppliedToProviders` set after a real init, instead of it
// staying permanently null because the old code required BOTH providers'
// writes to succeed even when only one is configured.
//
// Why on-device: this exercises the REAL `applovin_max`/`google_mobile_ads`
// native plugin channel calls, not a mocked MethodChannel — proving the fix
// holds against the real plugins' actual behavior (see ad_consent_test.dart's
// own T164 group for why AppLovin's fire-and-forget calls can't be
// meaningfully mocked to fail at all — this device run sidesteps that
// entirely by using the real plugin, whatever it actually does).
//
// Run with:
//   flutter test integration_test/r164_admob_only_consent_committed_test.dart \
//     -d <device-id> --dart-define=AD_PROVIDER_ADMOB=true --dart-define=SKIP_SPLASH_AD=true

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_consent.dart'
    show lastConsentAppliedToProviders;
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
      'an AdMob-only real init sets lastConsentAppliedToProviders, not '
      'permanently null', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    expect(lastConsentAppliedToProviders, isNotNull,
        reason: 'T164 — an AdMob-only app (this example app\'s own default '
            'under AD_PROVIDER_ADMOB=true) must be able to commit consent '
            'as applied to providers; the pre-fix code required BOTH '
            'AdMob AND AppLovin writes to succeed, which a single-provider '
            'app can never satisfy, leaving this null forever');
  });
}
