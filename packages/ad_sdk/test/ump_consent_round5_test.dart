// Regression tests for the round-5 consent fixes (audit_claude.md):
//
//  MJ32 — the consent form was re-shown on EVERY launch to an EEA user who
//         had already answered. The old code gated on
//         `isConsentFormAvailable()`, which reports whether a form *exists*,
//         not whether consent is *required*; a form stays available after
//         consent (that is what backs the Privacy Options entry point).
//         Confirmed on a real device before this fix: `status=obtained
//         formShown=true` on a cold restart.
//  BL1  — `_umpAttemptFailed` was `result.error != null` alone, so a result of
//         (error == null, canRequestAds == false) — what UMP returns when it
//         resolves from cache but cannot serve a form — matched neither retry
//         path. The gate stayed shut for the whole session: zero ads, no
//         self-heal short of an app restart.
//  m11  — with BL1 widening that flag, an EEA user who legitimately rejected
//         also looks like "gate closed", so the retry paths must not re-run
//         the flow at them.
//  MJ8  — concurrent callers must join one in-flight flow instead of each
//         starting their own (two consent forms, two racing gate writes).
//
// Same fake-channel setup as ump_skip_branch_lockout_test.dart: AppLovin
// provider, because AdMobAdapter needs far more native state than a method
// channel can fake under `flutter test`.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);

/// UMP's native `ConsentStatus` ordinals, as the plugin's codec encodes them.
const int _statusRequired = 2;
const int _statusObtained = 3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Per-test knobs for what the fake UMP reports back.
  late int status;
  late bool canRequestAds;
  late bool formAvailable;
  late List<String> umpCalls;

  setUp(() async {
    status = _statusObtained;
    canRequestAds = true;
    formAvailable = true;
    umpCalls = <String>[];

    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      umpCalls.add(call.method);
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return Future.value(null);
        case 'ConsentInformation#canRequestAds':
          return Future.value(canRequestAds);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(status);
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(formAvailable);
        case 'UserMessagingPlatform#loadAndShowConsentFormIfRequired':
          // A real form dismiss resolves with no error.
          return Future.value(null);
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
  });

  group('MJ32 — form is presented only when consent is actually required', () {
    test(
        'status obtained + a form still available does NOT present the form '
        '(the every-launch nag)', () async {
      status = _statusObtained;
      // The exact trap: UMP keeps reporting a form as available after the
      // user consented, because Privacy Options needs it to be.
      formAvailable = true;

      final r = await AdManager().requestUmpConsent();

      expect(
        umpCalls,
        isNot(contains(
            'UserMessagingPlatform#loadAndShowConsentFormIfRequired')),
        reason: 'consent was already obtained — presenting the form again is '
            'the bug this test exists for',
      );
      expect(r.formShown, isFalse);
      expect(r.status, ConsentStatus.obtained);
    });

    test('status required DOES present the form', () async {
      status = _statusRequired;
      canRequestAds = false;

      final r = await AdManager().requestUmpConsent();

      expect(
        umpCalls,
        contains('UserMessagingPlatform#loadAndShowConsentFormIfRequired'),
        reason: 'an EEA user who has not answered must still get the form',
      );
      expect(r.formShown, isTrue);
    });
  });

  group('BL1 — a closed gate with no error still counts as a failed attempt',
      () {
    test('error == null + canRequestAds == false arms the retry', () async {
      // Exactly what UMP returns on a flaky first launch in the EEA: the info
      // update resolves from cache (no error), but no form could be served,
      // so the gate cannot open yet.
      status = _statusRequired;
      canRequestAds = false;
      formAvailable = false;

      final r = await AdManager().requestUmpConsent();

      expect(r.error, isNull,
          reason: 'this is the case the old `error != null` check missed');
      expect(r.canRequestAds, isFalse);
      expect(AdManager().debugUmpAttemptFailed, isTrue,
          reason: 'both retry paths gate on this flag — false here is what '
              'wedged the gate shut for the whole session');
    });

    test('a fully resolved obtained result does NOT arm the retry', () async {
      status = _statusObtained;
      canRequestAds = true;

      await AdManager().requestUmpConsent();

      expect(AdManager().debugUmpAttemptFailed, isFalse);
    });
  });

  group('MJ8 — one consent flow at a time', () {
    test('concurrent callers join the same in-flight request', () async {
      status = _statusRequired;
      canRequestAds = false;

      final a = AdManager().requestUmpConsent();
      final b = AdManager().requestUmpConsent();

      final results = await Future.wait([a, b]);

      expect(identical(results[0], results[1]), isTrue,
          reason: 'the second caller must join the first flow, not start a '
              'second consent form');
      expect(
        umpCalls
            .where((m) =>
                m == 'UserMessagingPlatform#loadAndShowConsentFormIfRequired')
            .length,
        1,
        reason: 'two forms in a row is the user-visible symptom',
      );
    });

    test('the in-flight marker clears, so a later call still runs', () async {
      status = _statusRequired;
      canRequestAds = false;

      await AdManager().requestUmpConsent();
      umpCalls.clear();
      await AdManager().requestUmpConsent();

      expect(umpCalls, contains('ConsentInformation#requestConsentInfoUpdate'),
          reason: 'a stale in-flight future would silently swallow every '
              'later call — worse than the bug being fixed');
    });
  });
}
