// Round-73 audit — widget layer for the setDoNotSell fix. Flipping the real
// CcpaOptOutToggle after init used to make the SDK send AdMob an EMPTY
// test-device list (updateRequestConfiguration replaces the whole config), so
// QA/host devices started receiving live ads. The toggle is what a user
// actually taps, so the proof goes through it.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
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

const _config = AdConfig(
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
  safety: AdSafetyParams(dryRun: true),
  umpTagForUnderAgeOfConsent: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final gmaCalls = <MethodCall>[];

  const connMethod = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const connStatus = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );

  setUp(() async {
    gmaCalls.clear();
    // connectivity_plus has no native side under `flutter test`.
    messenger.setMockMethodCallHandler(connMethod, (call) async => ['wifi']);
    messenger.setMockMethodCallHandler(connStatus, (call) async => null);
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
    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
    messenger.setMockMethodCallHandler(_umpChannel, null);
    messenger.setMockMethodCallHandler(connMethod, null);
    messenger.setMockMethodCallHandler(connStatus, null);
  });

  List<String> lastTestDevices() {
    final calls = gmaCalls.where(
      (c) => c.method == 'MobileAds#updateRequestConfiguration',
    );
    expect(calls, isNotEmpty);
    for (final call in calls) {
      expect(
        call.arguments['tagForUnderAgeOfConsent'],
        TagForUnderAgeOfConsent.yes,
      );
    }
    return List<String>.from(calls.last.arguments['testDeviceIds'] as List);
  }

  Widget host() => const MaterialApp(home: Scaffold(body: CcpaOptOutToggle()));

  testWidgets('tapping the real toggle keeps host + QA test devices', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await AdManager().initialize(config: _config, onComplete: (_, _) {});
    });
    expect(AdManager().isInitialised, isTrue, reason: 'sanity');
    await tester.pumpWidget(host());
    await tester.pump();
    gmaCalls.clear();

    await tester.tap(find.byType(Switch));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(AdManager().doNotSell, isTrue, reason: 'sanity: the tap landed');
    final ids = lastTestDevices();
    expect(ids, contains('host-device-1'));
    for (final hash in kQaTestDeviceHashes) {
      expect(ids, contains(hash));
    }
  });

  testWidgets('tapping it back off keeps them too', (tester) async {
    await tester.runAsync(() async {
      await AdManager().initialize(config: _config, onComplete: (_, _) {});
    });
    await tester.pumpWidget(host());
    await tester.pump();

    await tester.tap(find.byType(Switch));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    gmaCalls.clear();

    await tester.tap(find.byType(Switch));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(AdManager().doNotSell, isFalse);
    expect(lastTestDevices(), contains('host-device-1'));
  });
}
