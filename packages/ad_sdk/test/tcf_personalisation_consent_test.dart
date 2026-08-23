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

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
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

/// Enough of an adapter for `isInitialised` to be true — the resume re-check
/// is a no-op before the SDK is up.
class _StubAdapter implements AdProviderAdapter {
  final List<AdConsent> applied = <AdConsent>[];

  @override
  void applyConsent(AdConsent consent) => applied.add(consent);

  @override
  String get tag => 'stub';

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  // A resolved future satisfies both the `Future`-returning members the
  // resume path touches (loadAppOpen) and the void ones.
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
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
    /// Non-null keeps the native privacy-options form "on screen": the channel
    /// call — and so the plugin's dismiss callback — only resolves when the
    /// test completes it.
    Completer<void>? privacyFormGate;

    setUp(() async {
      status = _statusObtained;
      canRequestAds = true;
      privacyOptionsRequirement = _privacyOptionsNotRequired;
      privacyFormGate = null;

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
          case 'UserMessagingPlatform#showPrivacyOptionsForm':
            final gate = privacyFormGate;
            if (gate != null) return gate.future.then((_) => null);
            return Future.value(null);
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
      debugFormDismissTimeoutOverride = null;
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
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

    // Round-13, device verification (Pixel 7 Pro, EEA debug geography) —
    // BLOCKER. Our own wait for the dismiss callback frees the caller while
    // the native form is still up, and the status was then read *before* the
    // user had chosen and never read again: withdrawing consent after a long
    // read left `nonPersonalizedAds=0` for the rest of the session. Verbatim
    // from the device log, with no applyConsent line after it:
    //   privacy options form dismiss timed out after 20s
    //   applyConsent → nonPersonalizedAds=false (hasUserConsent=true, …)
    //   Writing to storage: [IABTCF_PurposeConsents] 00000000000
    test(
        'Privacy Options: a dismiss arriving after our own timeout still '
        'applies the withdrawal', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'sanity: they consented first');

      privacyOptionsRequirement = _privacyOptionsRequired;
      debugFormDismissTimeoutOverride = const Duration(milliseconds: 20);
      final gate = Completer<void>();
      privacyFormGate = gate;

      final atTimeout = await AdManager().showPrivacyOptions();
      expect(atTimeout.error, contains('timed out'),
          reason: 'sanity: we gave up waiting while the form was still up');
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'nothing has changed yet — the user is still reading');

      // Now they actually withdraw and close the form.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      gate.complete();
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'a withdrawal made after our timeout is still a withdrawal; '
              'serving personalised ads for the rest of the session is the '
              'GDPR/DMA violation this test exists for');
    });

    // The backstop half: no dismiss callback arrives at all (a form torn down
    // by the OS, a plugin that drops the callback, a process resumed after the
    // form was answered). The CMP still wrote the choice to the TCF keys.
    test('resume re-applies a consent change this process never saw land',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue, reason: 'sanity');

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the device says personalisation was refused; what is '
              'applied to the providers must agree with it');
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'and the provider itself must be told, not just our cache');
    });

    test('resume with the device and the applied state in agreement is a no-op',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(adapter.applied, isEmpty,
          reason: 'every resume must not re-apply consent — that would churn '
              'the consent epoch and discard loaded ads for nothing');
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
