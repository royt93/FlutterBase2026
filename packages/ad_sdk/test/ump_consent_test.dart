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

  setUp(resetUmpFormOnScreen);

  tearDown(() {
    messenger.setMockMethodCallHandler(umpChannel, null);
    debugUmpFormBackstopOverride = null;
    debugFormDismissTimeoutOverride = null;
    // The counter is module-level, and after round-7's final QC a form that
    // times out DELIBERATELY keeps its ad block — so a timeout test would
    // otherwise hand its block to the next test.
    resetUmpFormOnScreen();
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
  // Round-7 audit, MAJOR — the native UMP form is not a Flutter route and does
  // not background the app, so nothing else in the SDK can see it. This flag is
  // the only signal `AdManager._fullscreenBusyReason` has, so it has to be true
  // for exactly as long as the form is on screen: an interstitial drawn over a
  // consent form steals the tap the consent choice needed, and is a policy
  // violation in its own right.
  test('umpFormOnScreen is held while the EEA consent form is presented',
      () async {
    bool? flagWhilePresenting;
    messenger.setMockMethodCallHandler(umpChannel, (call) async {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return null;
        case 'ConsentInformation#getConsentStatus':
          return 2; // required (Android mapping)
        case 'UserMessagingPlatform#loadAndShowConsentFormIfRequired':
          flagWhilePresenting = umpFormOnScreen.value;
          return null;
        case 'ConsentInformation#canRequestAds':
          return true;
        default:
          return null;
      }
    });

    expect(umpFormOnScreen.value, isFalse, reason: 'sanity: clear at rest');

    final result = await requestUmpConsentFlow();

    expect(result.formShown, isTrue, reason: 'sanity: a form was presented');
    expect(flagWhilePresenting, isTrue,
        reason: 'ads must be locked out from the moment the form goes up');
    expect(umpFormOnScreen.value, isFalse,
        reason: 'and unlocked again once the form is dismissed');
  });

  // Round-7 final QC, codex — the release used to sit in a `finally` around the
  // dismiss await, so `Future.timeout` firing was treated as "the form is gone".
  // It is not: `timeout` only stops Dart waiting, and with the Privacy Options
  // flow that happens 20 s into a user reading a GDPR form. The ad gate reopened
  // underneath a live consent form — the exact policy violation the flag exists
  // to prevent.
  test('the ad block outlives a dismiss timeout, because the form does',
      () async {
    // Real timers, shortened: the plugin only invokes its dismiss callback once
    // the platform call returns, and that round-trip does not run inside
    // fake_async's zone — so holding this open IS "the form is still up".
    debugFormDismissTimeoutOverride = const Duration(milliseconds: 100);
    final formCall = Completer<dynamic>();
    messenger.setMockMethodCallHandler(umpChannel, (call) async {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return null;
        case 'ConsentInformation#getConsentStatus':
          return 2; // required (Android mapping)
        case 'UserMessagingPlatform#loadAndShowConsentFormIfRequired':
          return formCall.future;
        case 'ConsentInformation#canRequestAds':
          return true;
        default:
          return null;
      }
    });

    final result = await requestUmpConsentFlow();

    expect(result.error, contains('timed out'),
        reason: 'the CALLER is freed by the timeout');
    expect(umpFormOnScreen.value, isTrue,
        reason: 'the form is still on screen — no ad may be drawn over it just '
            'because Dart stopped waiting for it. This used to flip to false '
            'in a `finally` around the await.');

    // Released when the form genuinely reports being dismissed, long after the
    // completer timed out.
    formCall.complete(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(umpFormOnScreen.value, isFalse);
  });

  test('two overlapping forms each hold the block until both are dismissed',
      () {
    final releaseA = markUmpFormOnScreen();
    final releaseB = markUmpFormOnScreen();
    expect(umpFormOnScreen.value, isTrue);

    releaseA();
    expect(umpFormOnScreen.value, isTrue,
        reason: 'the second form is still on screen — one shared boolean used '
            'to let whichever finished first unlock the gate');
    releaseA();
    expect(umpFormOnScreen.value, isTrue, reason: 'release is idempotent');

    releaseB();
    expect(umpFormOnScreen.value, isFalse);
  });

  test('a dismiss callback that never arrives is released by the backstop', () {
    debugUmpFormBackstopOverride = const Duration(minutes: 15);
    fakeAsync((async) {
      markUmpFormOnScreen();
      async.elapse(const Duration(minutes: 14));
      expect(umpFormOnScreen.value, isTrue);

      async.elapse(const Duration(minutes: 2));
      expect(umpFormOnScreen.value, isFalse,
          reason: 'a native form torn down without telling Dart must not block '
              'every fullscreen ad for the rest of the process');
    });
  });
}
