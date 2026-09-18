// Round-44 audit fix — setDoNotSell()'s own docstring says "Safe to call
// before initialize() — ConsentManager persists the choice through
// AdPreferences regardless." The implementation did the opposite: it
// checked `_consentManager == null`, logged "ignored", and returned,
// silently discarding the value. A CCPA/CPRA "Do Not Sell" gate that calls
// this before initialize() — exactly as the public API says is safe — lost
// the user's opt-out.
//
// Fix routes setDoNotSell through setConsent(), which already has this
// exact pre-init buffering (see consent_persistence_on_init_test.dart) —
// the docstring's claim was true of the SIBLING API, just not of this one.
//
// Same harness as consent_persistence_on_init_test.dart (AppLovin provider:
// its initialize() path is reachable in a plain `flutter test` run without
// the extra native-side state AdMob's AdInstanceManager needs).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');

final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);

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
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return Future.value(null);
        case 'ConsentInformation#canRequestAds':
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0); // unknown
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(false);
        default:
          return Future.value(null);
      }
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_umpChannel, null);
  });

  setUp(() async {
    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
  });

  tearDown(() async {
    await AdManager().destroy();
  });

  test(
      'setDoNotSell(true) called before initialize() survives initialize() '
      'and reaches ConsentManager (THE finding)', () async {
    SharedPreferences.setMockInitialValues({});

    // Real host order for a CCPA/CPRA opt-out gate shown on first launch,
    // same as the docstring's own claim: before initialize() has run.
    await AdManager().setDoNotSell(true);

    expect(AdManager().doNotSell, isTrue,
        reason: 'a read-back before initialize() must reflect the call — '
            'the old implementation silently discarded it, so this was '
            'always false here');

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, __) {},
    );

    expect(AdManager().isInitialised, isTrue,
        reason: 'adapter init must have actually succeeded for this test to '
            'prove anything about the post-init consent logic');
    expect(AdManager().doNotSell, isTrue,
        reason: 'THE finding — setDoNotSell()\'s own docstring promises '
            'this is safe pre-init; the pre-round-44 code dropped it');
    expect(AdManager().consentManager!.current.doNotSell, isTrue);

    // And it must actually be persisted, not just held in memory.
    final prefs = await AdPreferences.getInstance();
    final persisted = ConsentSettings.decode(prefs.getConsentSettingsRaw());
    expect(persisted.doNotSell, isTrue,
        reason: 'setDoNotSell() must write through even before initialize(), '
            'same as setConsent() already does');
  });

  test(
      'setDoNotSell(false) pre-init does not disturb hasUserConsent/'
      'isAgeRestrictedUser already set by a prior pre-init setConsent() call',
      () async {
    SharedPreferences.setMockInitialValues({});

    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, isAgeRestrictedUser: true));
    await AdManager().setDoNotSell(true);

    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'setDoNotSell must not clobber a sibling pre-init consent '
            'field it was not asked to change');
    expect(AdManager().consent.isAgeRestrictedUser, isTrue);
    expect(AdManager().doNotSell, isTrue);

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, __) {},
    );

    expect(AdManager().consent.hasUserConsent, isTrue);
    expect(AdManager().consent.isAgeRestrictedUser, isTrue);
    expect(AdManager().doNotSell, isTrue);
  });

  test('CONTROL — setDoNotSell(true) called AFTER initialize() still works '
      '(no regression)', () async {
    SharedPreferences.setMockInitialValues({});

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, __) {},
    );
    expect(AdManager().isInitialised, isTrue);

    await AdManager().setDoNotSell(true);

    expect(AdManager().doNotSell, isTrue);
    expect(AdManager().consentManager!.current.doNotSell, isTrue);
  });
}
