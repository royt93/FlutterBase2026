// T43/T44 — requestUmpConsentFlow() / requestPrivacyOptionsFlow() timeout
// guards.
//
// Both functions call straight into `ConsentInformation`/`ConsentForm`'s
// static APIs (no `*Override` seam like `att_consent.dart`), so the only way
// to drive them deterministically is mocking the underlying
// `plugins.flutter.io/google_mobile_ads/ump` method channel, same pattern as
// `privacy_options_test.dart`.
//
// T43 covers the `requestConsentInfoUpdate` guard: if the platform channel
// never replies (dead network to Google's consent servers), the flow must
// still return within 20s instead of hanging the whole splash boot chain.
// T44 covers the analogous guard on `requestPrivacyOptionsFlow()`'s
// `showPrivacyOptionsForm` dismiss await — a user-initiated re-consent call
// that must not hang forever either.

import 'dart:async';

import 'package:applovin_admob_sdk/src/core/ump_consent.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // Must match the real channel's codec exactly (StandardMethodCodec +
  // UserMessagingCodec) — the plain default codec can't decode the
  // ConsentRequestParameters arg the plugin sends, and corrupts the call
  // before our handler ever sees it.
  final umpChannel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads/ump',
    StandardMethodCodec(UserMessagingCodec()),
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(umpChannel, null);
  });

  test(
      'requestConsentInfoUpdate that never replies times out after 20s '
      'instead of hanging requestUmpConsentFlow() forever', () {
    messenger.setMockMethodCallHandler(umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          // Never completes — simulates a dead/slow connection to Google's
          // consent servers (the exact hang this guard exists for).
          return Completer<dynamic>().future;
        case 'ConsentInformation#canRequestAds':
          return Future.value(false);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0); // unknown
        default:
          return Future.value(null);
      }
    });

    fakeAsync((async) {
      UmpConsentResult? result;
      requestUmpConsentFlow().then((r) => result = r);

      async.elapse(const Duration(seconds: 20));

      expect(result, isNotNull,
          reason: 'requestUmpConsentFlow() must not hang forever when '
              'requestConsentInfoUpdate never replies');
      expect(result!.error, contains('timed out'));
      expect(result!.canRequestAds, isFalse);
    });
  });

  // T44 — requestPrivacyOptionsFlow()'s dismissCompleter guard. Same shape as
  // the T43 test above: the native form's dismiss callback only fires once
  // showPrivacyOptionsForm's platform call replies, which can hang forever if
  // the form is served but never dismissed.
  test(
      'showPrivacyOptionsForm that never replies times out after 20s '
      'instead of hanging requestPrivacyOptionsFlow() forever', () {
    messenger.setMockMethodCallHandler(umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#getPrivacyOptionsRequirementStatus':
          return Future.value(1); // required
        case 'UserMessagingPlatform#showPrivacyOptionsForm':
          // Never completes — simulates the form being served but never
          // dismissed (the exact hang this guard exists for).
          return Completer<dynamic>().future;
        case 'ConsentInformation#canRequestAds':
          return Future.value(false);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0); // unknown
        default:
          return Future.value(null);
      }
    });

    fakeAsync((async) {
      PrivacyOptionsResult? result;
      requestPrivacyOptionsFlow().then((r) => result = r);

      async.elapse(const Duration(seconds: 20));

      expect(result, isNotNull,
          reason: 'requestPrivacyOptionsFlow() must not hang forever when '
              'showPrivacyOptionsForm never replies');
      expect(result!.error, contains('timed out'));
      expect(result!.canRequestAds, isFalse);
    });
  });
}
