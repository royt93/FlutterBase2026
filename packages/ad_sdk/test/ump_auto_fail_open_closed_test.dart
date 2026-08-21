// Unit tests for Issue 1 — initialize()'s autoRequestUmpConsent branch must
// fail OPEN only for MissingPluginException (UMP channel not registered —
// i.e. UMP simply isn't wired for this host) and fail CLOSED for any other
// exception (a real consent-fetch failure, with the channel actually wired).
//
// AdManager().debugForceAutoUmpError lets a test force the exact exception
// the runZonedGuarded catch handler sees, without needing a real UMP channel
// failure — see ad_manager.dart's `_onCanRequestAdsChanged`-adjacent comment
// block above `if (e is MissingPluginException)` for the compliance
// rationale (fail-closed unless UMP is provably not wired).
//
// Provider is AppLovin, not AdMob: AdMobAdapter.initialize() reaches into
// google_mobile_ads' AdInstanceManager, which needs far more native-side
// state than a method channel returning null can fake, so it always fails in
// a plain `flutter test` run (see consent_persistence_on_init_test.dart's
// header comment for the same constraint). AppLovinAdapter.initialize() just
// awaits AppLovinMAX.initialize(sdkKey), satisfied by the channel returning
// an (empty, all-nullable) config map.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

AdConfig _appLovinConfig() => const AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(
        sdkKey: 'test-sdk-key',
        bannerId: 'banner-id',
        interstitialId: 'interstitial-id',
        appOpenId: 'appopen-id',
        rewardedId: 'rewarded-id',
      ),
      safety: AdSafetyParams(dryRun: true),
      autoRequestUmpConsent: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    // applyConsentToProviders() unconditionally touches MobileAds.instance
    // regardless of the active provider — an unmocked _gmaChannel would
    // throw a stray, unrelated MissingPluginException here too.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
  });

  tearDown(() async {
    AdManager().debugForceAutoUmpError = null;
    await AdManager().destroy();
  });

  test('MissingPluginException fails OPEN — gate reopens', () async {
    SharedPreferences.setMockInitialValues({});
    AdManager().debugForceAutoUmpError =
        MissingPluginException('forced for test');

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().canRequestAds, isTrue,
        reason: 'UMP not wired (simulated via MissingPluginException) must '
            'fail OPEN so ads are not permanently blocked for a host that '
            'never wires the UMP channel');
    expect(AdManager().debugUmpAttemptFailed, isTrue);
  });

  test('a non-MissingPluginException fails CLOSED — gate stays shut',
      () async {
    SharedPreferences.setMockInitialValues({});
    AdManager().debugForceAutoUmpError = Exception('forced network failure');

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, __) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().canRequestAds, isFalse,
        reason: 'a genuine consent-fetch failure (channel IS wired) must '
            'keep the gate closed — failing open here would ship ads with '
            'no verified consent decision');
    expect(AdManager().debugUmpAttemptFailed, isTrue);
  });
}
