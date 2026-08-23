// Round-6 audit, BLOCKER — "the form was completed" is not "the user agreed".
//
// UMP reports `ConsentStatus.obtained` as soon as the EEA consent form is
// SUBMITTED, whatever the user ticked. `canRequestAds` stays true too, because
// non-personalised ads remain servable. The SDK derived `hasUserConsent` from
// that status alone, so a user who opened the form and rejected every purpose
// was handed `hasUserConsent: true` → AppLovin `setHasUserConsent(true)`,
// AdMob `nonPersonalizedAds=false`, i.e. personalised ads served to someone
// who had explicitly refused, with their own form submission as the evidence.
//
// The fix reads the real answer back out of the IAB TCF purpose bitfield the
// CMP wrote (`IabStorage.tcfAllowsPersonalisedAds`). Two paths needed it:
// `_applyUmpConsentResult` (first-launch flow) and `showPrivacyOptions()` —
// the second is the sharper one, since Privacy Options IS the withdrawal path.
//
// Part 1 pins the bitfield parsing. Parts 2 and 3 pin the wiring, driving the
// real UMP method channel the way ump_consent_round5_test.dart does.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);

/// UMP's native ordinals, as the plugin's codec encodes them.
const int _statusObtained = 3;
const int _privacyOptionsRequired = 1;
const int _privacyOptionsNotRequired = 0;

/// A TCF purpose bitfield that consents to purposes 1, 3 and 4 — the three
/// personalised-advertising purposes — and nothing else.
const String _purposesAllow = '1011000000';

/// The same user with purpose 4 ("use profiles to select personalised
/// advertising") refused. One missing purpose is enough.
const String _purposesRefuse = '1010000000';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void seedTcf(Map<String, Object> data) {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(data);
  }

  group('IabStorage.tcfAllowsPersonalisedAds', () {
    test('no TCF signal at all → null, NOT a refusal', () async {
      seedTcf({});
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isNull,
          reason: 'the normal case outside the EEA. Reading this as `false` '
              'would downgrade every non-EEA user to non-personalised ads');
    });

    test('GDPR explicitly does not apply → allowed', () async {
      seedTcf({'IABTCF_gdprApplies': 0});
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isTrue,
          reason: 'the purpose bitfield is not populated meaningfully out of '
              'scope, so refusing on it would be wrong');
    });

    test('GDPR applies but no purposes were recorded → refused', () async {
      seedTcf({'IABTCF_gdprApplies': 1});
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isFalse);
    });

    test('purposes 1 + 3 + 4 all consented → allowed', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isTrue);
    });

    test('purpose 4 refused → refused', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isFalse);
    });

    test('purpose 1 refused → refused', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': '0011000000',
      });
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isFalse);
    });

    test('purpose 3 refused → refused', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': '1001000000',
      });
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isFalse);
    });

    test('a truncated bitfield is a refusal, not a guess', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': '11',
      });
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isFalse);
    });

    test('purposes present without gdprApplies is still decided', () async {
      // Some CMPs omit `IABTCF_gdprApplies`. A populated purpose bitfield is
      // itself proof a TCF session ran, so it must be honoured.
      seedTcf({'IABTCF_PurposeConsents': _purposesRefuse});
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isFalse);
    });
  });

  group('the UMP flow honours the TCF purposes, not just the status', () {
    late int status;
    late bool canRequestAds;
    late int privacyOptionsRequirement;

    setUp(() async {
      status = _statusObtained;
      canRequestAds = true;
      privacyOptionsRequirement = _privacyOptionsNotRequired;

      messenger.setMockMethodCallHandler(_alChannel, (call) async {
        if (call.method == 'initialize') return <String, dynamic>{};
        return null;
      });
      messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
      messenger.setMockMethodCallHandler(_umpChannel, (call) {
        switch (call.method) {
          case 'ConsentInformation#canRequestAds':
            return Future.value(canRequestAds);
          case 'ConsentInformation#getConsentStatus':
            return Future.value(status);
          case 'ConsentInformation#isConsentFormAvailable':
            return Future.value(true);
          case 'ConsentInformation#getPrivacyOptionsRequirementStatus':
            return Future.value(privacyOptionsRequirement);
          default:
            // requestConsentInfoUpdate, loadAndShowConsentFormIfRequired and
            // showPrivacyOptionsForm all resolve with null on success.
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
    });

    test(
        'status=obtained but the purposes refuse → hasUserConsent false '
        '(the blocker)', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });

      final r = await AdManager().requestUmpConsent();

      expect(r.status, ConsentStatus.obtained,
          reason: 'sanity: UMP itself is happy — the form WAS completed');
      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the user rejected a personalisation purpose in that very '
              'form. Serving personalised ads here is the GDPR/DMA violation '
              'this test exists for');
    });

    test('status=obtained with the purposes consented → hasUserConsent true',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });

      await AdManager().requestUmpConsent();

      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'the other half of the invariant — a real consent must not '
              'be downgraded');
    });

    test('no TCF signal at all keeps the old status-only mapping', () async {
      seedTcf({});

      await AdManager().requestUmpConsent();

      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'outside the EEA there is no bitfield to read, so UMP\'s '
              'status is the whole answer. Falling to false here would mean '
              'non-personalised ads worldwide');
    });

    test(
        'Privacy Options: withdrawing personalisation flips hasUserConsent '
        'back to false', () async {
      // The withdrawal path, and the reason this needed fixing in two places:
      // a user who consented on first launch, then reopened Privacy Options
      // specifically to turn personalisation off, submitted the form and got
      // `obtained` — which used to be re-applied as `hasUserConsent: true`.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'sanity: they consented first');

      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });

      await AdManager().showPrivacyOptions();

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'personalised ads must stop the moment the withdrawal form '
              'is submitted');
    });

    test('Privacy Options: re-confirming consent leaves it granted', () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });

      await AdManager().showPrivacyOptions();

      expect(AdManager().consent.hasUserConsent, isTrue);
    });
  });
}
