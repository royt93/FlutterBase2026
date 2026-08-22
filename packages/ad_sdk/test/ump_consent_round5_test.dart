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
//  M6   — (2026-08-22 audit, independent review) the mutex itself had no
//         deadline: `_requestUmpConsent` awaits `setConsent()` ->
//         `ConsentManager.set()` -> `_applyToProviders()` ->
//         `MobileAds.instance.updateRequestConfiguration()`, none of which is
//         bounded, so a hang there joined every later caller to a future that
//         could never complete — worse than the BL1 lockout this round set
//         out to fix. The fix wraps the whole flow in a 240s `.timeout`, and
//         releases the lock only if the completing call still owns it
//         (`identical(_umpInFlight, started)`), since `_resetGuardState()`
//         (a re-init) can null it out from under a still-hung older call.
//
// Same fake-channel setup as ump_skip_branch_lockout_test.dart: AppLovin
// provider, because AdMobAdapter needs far more native state than a method
// channel can fake under `flutter test`.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Always succeeds instantly — only used to get `AdManager` into an
/// initialised state so `_resetGuardState()` is reachable through the real
/// re-init path, not a hand-rolled call to a private method.
class _InstantAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  @override
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;
  @override
  String get tag => '[instant]';

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;

  @override
  Future<void> dispose() async {}

  @override
  void applyConsent(AdConsent consent) {}

  // initialize() unconditionally kicks these off on success (post-init
  // App Open + banner/mrec warm-up) — no-op so that doesn't throw through
  // noSuchMethod and schedule a real background retry timer that outlives
  // this test.
  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {}
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  autoRequestUmpConsent: false,
  enableCrashGuard: false,
  // AppLovin's own CMP counts as consent coverage (consentFootgunWarning),
  // so re-initialising mid-test (simulating a host destroy()+initialize()
  // while UMP is stuck) doesn't trip the unrelated "no consent flow will
  // run" assert on every re-entry — that assert isn't what these tests are
  // about.
  disableAppLovinCmpFlow: false,
  // Not under test here, and its 30s real-time expiry timer would otherwise
  // race the slower tests in this file (they take several real seconds).
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  appLovin: AppLovinConfig(
    sdkKey: 'key',
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

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
    AdManager.debugAdapterFactory = null;
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

  group('M-3 — abandoned-form recovery does not mute the whole session', () {
    tearDown(() => debugFormDismissTimeoutOverride = null);

    test(
        'user answering the still-open form after our timeout is picked up '
        'by the recheck, not muted forever', () async {
      status = _statusRequired;
      canRequestAds = false;
      formAvailable = true;
      // Our own dismiss timeout fires long before the native form is
      // actually dismissed — the exact "form abandoned" scenario.
      debugFormDismissTimeoutOverride = const Duration(milliseconds: 20);
      final formDismiss = Completer<Object?>();
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
            return formDismiss.future; // never resolves on its own
          default:
            return Future.value(null);
        }
      });

      final r = await AdManager().requestUmpConsent();
      expect(r.formShown, isTrue);
      expect(AdManager().debugUmpFormAbandoned, isTrue,
          reason: 'sanity: our own timeout must have fired first');

      // The recheck must not clear the mute while the user genuinely still
      // hasn't answered — status/canRequestAds haven't changed yet.
      umpCalls.clear();
      await AdManager().debugRecheckAbandonedUmpForm();
      expect(
        umpCalls,
        isNot(contains(
            'UserMessagingPlatform#loadAndShowConsentFormIfRequired')),
        reason: 'M-3: recheck must never present a form — one may still be '
            'on screen',
      );
      expect(AdManager().debugUmpFormAbandoned, isTrue,
          reason: 'still unanswered — must stay muted so a later backstop '
              'tick keeps rechecking instead of presenting a second form');

      // The user now answers the still-open native form — reflected purely
      // in what canRequestAds()/getConsentStatus() report, same as the real
      // SDK would after a form dismiss.
      status = _statusObtained;
      canRequestAds = true;
      await AdManager().debugRecheckAbandonedUmpForm();

      expect(AdManager().debugUmpFormAbandoned, isFalse,
          reason: 'M-3: the whole point of this fix — once resolved, the '
              'mute must actually lift, not persist for the rest of the '
              'session');
      expect(AdManager().canRequestAds, isTrue);
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

  group('M6 — the 240s cap on the mutex itself', () {
    // A full AdManager.initialize() (VipManager, FirstInstallGuard, GAID...)
    // does not settle inside a fakeAsync zone (some of that chain does not
    // resolve through plain microtask/timer pumping), so bootstrap for real
    // outside fakeAsync first; only the requestUmpConsent() chain itself
    // (already proven to behave under fakeAsync by the MJ8 tests above) runs
    // inside the fakeAsync block that needs virtual-time control.
    setUp(() async {
      AdManager.debugAdapterFactory = (config) => _InstantAdapter();
      await AdManager()
          .initialize(config: _appLovinConfig, onComplete: (_, __) {});
      expect(AdManager().isInitialised, isTrue);
      umpCalls.clear();
    });

    test(
        'a hang deep in setConsent() (AdMob updateRequestConfiguration) '
        'releases the lock after 240s instead of never', () {
      fakeAsync((async) {
        status = _statusObtained;
        canRequestAds = true;
        // The unbounded step M6 targets: not UMP's own form flow (which has
        // its own inner timeouts) but the tail of setConsent() ->
        // ConsentManager.set() -> _applyToProviders() ->
        // MobileAds.instance.updateRequestConfiguration(), which had none.
        messenger.setMockMethodCallHandler(_gmaChannel, (call) {
          if (call.method == 'MobileAds#updateRequestConfiguration') {
            return Completer<void>().future; // never completes
          }
          return Future<void>.value();
        });

        UmpConsentResult? result;
        unawaited(AdManager().requestUmpConsent().then((r) => result = r));
        async.elapse(const Duration(seconds: 241));

        expect(result, isNotNull,
            reason: 'M6: the 240s cap must release the lock instead of '
                'hanging forever');
        expect(result!.error, contains('240s'));

        // Prove the lock itself was actually released — a later call must
        // start a fresh flow, not join a dead future forever.
        messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
        umpCalls.clear();
        UmpConsentResult? second;
        unawaited(AdManager().requestUmpConsent().then((r) => second = r));
        async.elapse(const Duration(seconds: 1));

        expect(second, isNotNull);
        expect(
            umpCalls, contains('ConsentInformation#requestConsentInfoUpdate'),
            reason: 'a released lock must let a later call actually run '
                'again, not join the timed-out future');
      });
    });
  });
}
