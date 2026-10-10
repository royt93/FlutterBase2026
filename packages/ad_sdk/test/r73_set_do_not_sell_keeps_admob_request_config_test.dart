// Round-73 audit finding — a post-init AdManager().setDoNotSell() called
// ConsentManager.set() without a config, so applyConsentToProviders() sent
// AdMob an updateRequestConfiguration with testDeviceIds=[] (the call
// REPLACES the whole global config). The QA fleet and host test devices were
// silently dropped for the rest of the session.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show TagForUnderAgeOfConsent;
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');
final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);
final _gmaChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads',
  StandardMethodCodec(AdMessageCodec()),
);

AdConfig _config({bool underAge = false}) => AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'test-sdk-key',
    bannerId: 'banner-id',
    interstitialId: 'interstitial-id',
    appOpenId: 'appopen-id',
    rewardedId: 'rewarded-id',
  ),
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    testDeviceIds: ['host-device-1'],
  ),
  safety: const AdSafetyParams(dryRun: true),
  umpTagForUnderAgeOfConsent: underAge,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final gmaCalls = <MethodCall>[];

  setUpAll(() {
    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async {
      gmaCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#canRequestAds':
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0);
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(false);
        default:
          return Future.value(null);
      }
    });
  });

  tearDownAll(() {
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
    messenger.setMockMethodCallHandler(_umpChannel, null);
  });

  setUp(() async {
    gmaCalls.clear();
    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await AdManager().destroy();
  });

  List<String> lastTestDeviceIds() {
    final calls = gmaCalls.where(
      (c) => c.method == 'MobileAds#updateRequestConfiguration',
    );
    expect(
      calls,
      isNotEmpty,
      reason: 'the post-init call must reach AdMob at all',
    );
    return List<String>.from(calls.last.arguments['testDeviceIds'] as List);
  }

  test(
    'post-init setDoNotSell keeps host + QA test devices registered',
    () async {
      await AdManager().initialize(config: _config(), onComplete: (_, _) {});
      expect(AdManager().isInitialised, isTrue);
      gmaCalls.clear();

      await AdManager().setDoNotSell(true);

      final ids = lastTestDeviceIds();
      expect(
        ids,
        contains('host-device-1'),
        reason: 'host test device must survive a CCPA toggle',
      );
      for (final hash in kQaTestDeviceHashes) {
        expect(
          ids,
          contains(hash),
          reason: 'always-on QA fleet must survive a CCPA toggle',
        );
      }
    },
  );

  test(
    'direct ConsentManager.set keeps host/QA test devices and TFUA',
    () async {
      await AdManager().initialize(
        config: _config(underAge: true),
        onComplete: (_, _) {},
      );
      expect(AdManager().isInitialised, isTrue);
      gmaCalls.clear();

      final current = AdManager().consentManager!.current;
      await AdManager().consentManager!.set(current.copyWith(doNotSell: true));

      final updates = gmaCalls.where(
        (call) => call.method == 'MobileAds#updateRequestConfiguration',
      );
      expect(updates, isNotEmpty);
      for (final call in updates) {
        final ids = List<String>.from(call.arguments['testDeviceIds'] as List);
        expect(ids, contains('host-device-1'));
        expect(ids, containsAll(kQaTestDeviceHashes));
        expect(
          call.arguments['tagForUnderAgeOfConsent'],
          TagForUnderAgeOfConsent.yes,
        );
      }
    },
  );

  test('toggling CCPA back off also keeps the test devices', () async {
    await AdManager().initialize(config: _config(), onComplete: (_, _) {});
    await AdManager().setDoNotSell(true);
    gmaCalls.clear();

    await AdManager().setDoNotSell(false);

    expect(lastTestDeviceIds(), contains('host-device-1'));
  });

  for (final underAge in [true, false]) {
    test('CCPA toggles preserve TFUA when underAge=$underAge', () async {
      await AdManager().initialize(
        config: _config(underAge: underAge),
        onComplete: (_, _) {},
      );
      expect(AdManager().isInitialised, isTrue);
      for (final optOut in [true, false]) {
        gmaCalls.clear();
        await AdManager().setDoNotSell(optOut);
        final updates = gmaCalls.where(
          (call) => call.method == 'MobileAds#updateRequestConfiguration',
        );
        expect(updates, isNotEmpty);
        for (final call in updates) {
          expect(
            call.arguments['tagForUnderAgeOfConsent'],
            underAge
                ? TagForUnderAgeOfConsent.yes
                : TagForUnderAgeOfConsent.unspecified,
          );
          expect(call.arguments['testDeviceIds'], contains('host-device-1'));
        }
      }
    });
  }
}
