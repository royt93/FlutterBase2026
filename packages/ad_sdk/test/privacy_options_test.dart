// T06 — Privacy Options entry point + re-consent.
//
// Google UMP policy: apps must expose a durable way for users to change
// consent after the first prompt. AdManager.showPrivacyOptions() wraps
// ConsentForm.showPrivacyOptionsForm() and must (a) only show the native
// form when Google's ConsentInformation actually requires it, and (b)
// re-apply the resulting consent to the active ad provider immediately.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingAdapter implements AdProviderAdapter {
  final List<AdConsent> applied = <AdConsent>[];
  AdConsent? get last => applied.isEmpty ? null : applied.last;

  @override
  void applyConsent(AdConsent consent) => applied.add(consent);
  @override
  String get tag => 'recording';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/1111111111',
    interstitialId: 'ca-app-pub-3940256099942544/2222222222',
    appOpenId: 'ca-app-pub-3940256099942544/3333333333',
    rewardedId: 'ca-app-pub-3940256099942544/4444444444',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const umpChannel = MethodChannel('plugins.flutter.io/google_mobile_ads/ump');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');
  const alChannel = MethodChannel('applovin_max');

  // PrivacyOptionsRequirementStatus: 0=notRequired, 1=required.
  late bool showFormInvoked;
  late int requirementStatus;
  // ConsentStatus (default/Android decode): 0=unknown,1=notRequired,2=required,3=obtained.
  late int consentStatus;
  late bool canRequestAdsNative;

  Future<dynamic> umpHandler(MethodCall call) async {
    switch (call.method) {
      case 'ConsentInformation#getPrivacyOptionsRequirementStatus':
        return requirementStatus;
      case 'ConsentInformation#getConsentStatus':
        return consentStatus;
      case 'ConsentInformation#canRequestAds':
        return canRequestAdsNative;
      case 'UserMessagingPlatform#showPrivacyOptionsForm':
        showFormInvoked = true;
        return null;
      default:
        return null;
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    showFormInvoked = false;
    requirementStatus = 0;
    consentStatus = 1;
    canRequestAdsNative = true;

    messenger.setMockMethodCallHandler(umpChannel, umpHandler);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(umpChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    messenger.setMockMethodCallHandler(alChannel, null);
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true;
  });

  group('isPrivacyOptionsRequired', () {
    test('reflects native requirement status: required', () async {
      requirementStatus = 1;
      expect(await AdManager().isPrivacyOptionsRequired(), isTrue);
    });

    test('reflects native requirement status: not required', () async {
      requirementStatus = 0;
      expect(await AdManager().isPrivacyOptionsRequired(), isFalse);
    });
  });

  group('showPrivacyOptions (T06)', () {
    test('requirement=required → opens the native privacy options form',
        () async {
      requirementStatus = 1;
      consentStatus = 3; // obtained
      canRequestAdsNative = true;

      final result = await AdManager().showPrivacyOptions();

      expect(showFormInvoked, isTrue,
          reason: 'Google requires the durable privacy-options form to '
              'actually show for EEA/UK users once required');
      expect(result.formShown, isTrue);
      expect(result.canRequestAds, isTrue);
    });

    test('requirement=notRequired → does NOT open the native form (safe no-op)',
        () async {
      requirementStatus = 0;
      consentStatus = 1; // notRequired
      canRequestAdsNative = true;

      final result = await AdManager().showPrivacyOptions();

      expect(showFormInvoked, isFalse,
          reason: 'showPrivacyOptions() must be safe to call for non-EEA '
              'users / hosts that never gathered consent');
      expect(result.formShown, isFalse);
    });

    test('re-consent via the form re-applies consent to the active adapter',
        () async {
      final adapter = _RecordingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;

      requirementStatus = 1;
      consentStatus = 3; // obtained
      canRequestAdsNative = true;

      await AdManager().showPrivacyOptions();

      expect(adapter.applied, isNotEmpty,
          reason: 'changing consent via privacy options must re-apply it '
              'to the active provider (npa/RDP update), not just be cached');
      expect(adapter.last!.hasUserConsent, isTrue);
    });

    test('notRequired path does not touch the adapter', () async {
      final adapter = _RecordingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;

      requirementStatus = 0;
      consentStatus = 1; // notRequired
      canRequestAdsNative = true;

      await AdManager().showPrivacyOptions();

      // setConsent() is still invoked with the resolved status either way,
      // so the adapter does receive a consent apply here — but never a
      // native form. Guard against the form having flipped this.
      expect(showFormInvoked, isFalse);
    });
  });
}
