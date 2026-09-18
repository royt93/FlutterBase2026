// Audit fix (post-T210) — `ConsentFallbackState`/`ConsentManager.recordFallback`
// had unit coverage for the pure DATA class (encode/decode/migration, see
// `consent_fallback_test.dart`), but nothing exercised the actual PRODUCTION
// WIRING in `AdManager._requestUmpConsent` that decides which
// `ConsentFallbackReason` to record. That wiring had two real gaps:
//
//  - `ConsentFallbackReason.offline` was declared but never produced — every
//    UMP failure was classified as `timeout` or `platformError` even when the
//    device had no connectivity at all.
//  - `policyRevision` was the hardcoded literal `'ump-v1'`, not the shared
//    `kUmpPolicyRevision` constant, so a `ConsentManager` reload could never
//    detect a policy-revision bump and reclassify a stale fallback record.
//
// These tests exercise the real `AdManager().requestUmpConsent()` path (not
// `requestUmpConsentFlow()` directly, which only has T43's channel-level
// coverage) with a bootstrapped `ConsentManager`, same fake-UMP-channel setup
// as `ump_consent_round5_test.dart`.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);

const int _statusObtained = 3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ConsentManager cm;

  setUp(() async {
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    cm = await ConsentManager.bootstrap(prefs: prefs);
    AdManager().debugConsentManager = cm;
    AdManager().debugReconnectDebounce = Duration.zero;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_gmaChannel, null);
    messenger.setMockMethodCallHandler(_umpChannel, null);
    AdManager().debugConsentManager = null;
    AdManager().debugConnectivityReady = false;
    ConsentManager.resetForTest();
  });

  test(
      'a UMP failure while the device is offline records an offline '
      'fallback, not timeout/platformError', () {
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return Completer<dynamic>().future; // never replies → 20s timeout
        case 'ConsentInformation#canRequestAds':
          return Future.value(false);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0); // unknown
        default:
          return Future.value(null);
      }
    });

    fakeAsync((async) {
      // codex round-1 fix — `debugConnectivityReady = true` marks this as a
      // REAL confirmed reading (not the pre-ready optimistic default the
      // production fix now specifically excludes from `offline`
      // classification), matching a device whose connectivity watch has
      // already resolved.
      AdManager().debugConnectivityReady = true;
      AdManager().debugConnectivityChanged(false); // offline
      UmpConsentResult? result;
      unawaited(AdManager().requestUmpConsent().then((r) => result = r));
      async.elapse(const Duration(seconds: 20));

      expect(result, isNotNull);
      expect(result!.error, contains('timed out'));
      expect(cm.fallback?.reason, ConsentFallbackReason.offline,
          reason: 'the device was offline — that must be recorded even '
              'though the underlying error text is a generic timeout');
      expect(cm.fallback?.policyRevision, kUmpPolicyRevision);
    });
  });

  test(
      'codex round-1 fix — a UMP failure BEFORE the connectivity watch has '
      'ever resolved records timeout/platformError, not a guessed offline',
      () {
    // `debugConnectivityReady` is left at its default (false) — this is the
    // documented common case: requestUmpConsent() called from splash before
    // initialize() (and its connectivity watch) has run at all. isConnected
    // would optimistically read `true` here, but this must not be trusted
    // as a real "online" reading either — the point is that with NO real
    // reading yet, this must not guess `offline`.
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return Completer<dynamic>().future;
        case 'ConsentInformation#canRequestAds':
          return Future.value(false);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0);
        default:
          return Future.value(null);
      }
    });

    fakeAsync((async) {
      UmpConsentResult? result;
      unawaited(AdManager().requestUmpConsent().then((r) => result = r));
      async.elapse(const Duration(seconds: 20));

      expect(result, isNotNull);
      expect(cm.fallback?.reason, ConsentFallbackReason.timeout,
          reason: 'no real connectivity reading exists yet — must fall '
              'back to the text-based classification, not guess offline '
              'from the optimistic pre-ready default');
    });
  });

  test(
      'the exact same failure while online records timeout, not offline',
      () {
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return Completer<dynamic>().future;
        case 'ConsentInformation#canRequestAds':
          return Future.value(false);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0);
        default:
          return Future.value(null);
      }
    });

    fakeAsync((async) {
      AdManager().debugConnectivityChanged(true); // online
      UmpConsentResult? result;
      unawaited(AdManager().requestUmpConsent().then((r) => result = r));
      async.elapse(const Duration(seconds: 20));

      expect(result, isNotNull);
      expect(cm.fallback?.reason, ConsentFallbackReason.timeout);
    });
  });

  test('a successful UMP resolution clears any previously recorded fallback',
      () async {
    await cm.recordFallback(
      reason: ConsentFallbackReason.platformError,
      policyRevision: kUmpPolicyRevision,
    );
    expect(cm.fallback, isNotNull, reason: 'sanity: pre-seeded');

    messenger.setMockMethodCallHandler(_umpChannel, (call) async {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return null;
        case 'ConsentInformation#canRequestAds':
          return true;
        case 'ConsentInformation#getConsentStatus':
          return _statusObtained;
        case 'ConsentInformation#isConsentFormAvailable':
          return false;
        default:
          return null;
      }
    });

    await AdManager().requestUmpConsent();

    expect(cm.fallback, isNull,
        reason: 'a clean resolution must clear stale fallback provenance');
  });
}
