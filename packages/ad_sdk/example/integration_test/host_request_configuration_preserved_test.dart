// On-device: does the SDK's own updateRequestConfiguration (initialize and every
// consent change) wipe a host-set maxAdContentRating? Reads the REAL native
// configuration back through MobileAds.getRequestConfiguration().
//
// Run:
//   flutter test integration_test/host_request_configuration_preserved_test.dart \
//     -d <device-id> --dart-define=AD_PROVIDER_ADMOB=true

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:integration_test/integration_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets('host maxAdContentRating survives init and setConsent', (
    tester,
  ) async {
    // The host sets its rating BEFORE the SDK initialises.
    await MobileAds.instance.updateRequestConfiguration(
      RequestConfiguration(maxAdContentRating: MaxAdContentRating.g),
    );
    final before = await MobileAds.instance.getRequestConfiguration();
    // ignore: avoid_print
    print('RC_BEFORE rating=${before.maxAdContentRating}');
    expect(before.maxAdContentRating, MaxAdContentRating.g,
        reason: 'precondition: the host rating was applied');

    var done = false;
    await AdManager().initialize(
      config: _config,
      onComplete: (ok, _) => done = ok,
    );
    for (var i = 0; i < 120 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(done, isTrue, reason: 'SDK must finish initialising');

    final afterInit = await MobileAds.instance.getRequestConfiguration();
    // ignore: avoid_print
    print('RC_AFTER_INIT rating=${afterInit.maxAdContentRating} '
        'testIds=${afterInit.testDeviceIds?.length}');

    await AdManager().setConsent(
      const AdConsent(hasUserConsent: false, isAgeRestrictedUser: false),
    );
    await tester.pump(const Duration(seconds: 1));
    final afterConsent = await MobileAds.instance.getRequestConfiguration();
    // ignore: avoid_print
    print('RC_AFTER_CONSENT rating=${afterConsent.maxAdContentRating}');

    expect(afterInit.maxAdContentRating, MaxAdContentRating.g,
        reason: 'initialize() must not reset the host rating');
    expect(afterConsent.maxAdContentRating, MaxAdContentRating.g,
        reason: 'setConsent() must not reset the host rating');
  });
}
