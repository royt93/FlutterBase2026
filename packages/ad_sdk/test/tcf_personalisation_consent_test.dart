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
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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

  /// Every adapter member the SDK touched, in order, so a test can pin
  /// *ordering* and not just the end state.
  final List<String> calls = <String>[];

  @override
  void applyConsent(AdConsent consent) {
    applied.add(consent);
    calls.add('applyConsent');
  }

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
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    calls.add(name.substring(
        name.indexOf('"') + 1, name.lastIndexOf('"').clamp(0, name.length)));
    return Future<void>.value();
  }
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

/// A preferences store whose *consent* write can be made to fail, and only
/// that one — every other key (safety counters, VIP) still writes fine.
///
/// Round-18 QC: `ConsentManager.set()` updates its in-memory value FIRST,
/// persists SECOND and only then applies to the providers. A persist that
/// throws — a full disk, an OEM keystore-backed store that refuses the write —
/// therefore leaves the SDK's own record saying "withdrawn" while both
/// providers are still configured for personalised ads. Anything that reads
/// that in-memory value to decide whether the device state is already applied
/// would call it settled and walk away.
class _FailableConsentStore extends InMemorySharedPreferencesStore {
  _FailableConsentStore() : super.empty();

  /// The prefixed key `AdPreferences` persists `ConsentSettings` under.
  static const String consentKey = 'flutter.ad_sdk_consent_settings_v1';

  bool failConsentWrite = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (failConsentWrite && key == consentKey) {
      return Future<bool>.error(PlatformException(
          code: 'ENOSPC', message: 'the consent store is full'));
    }
    return super.setValue(valueType, key, value);
  }
}

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

    /// Non-null wedges `getConsentStatus` — the UMP call the resume re-check
    /// makes once the TCF keys disagree with what is applied.
    Completer<void>? statusGate;

    /// True makes every `getConsentStatus` call fail, not just one — a
    /// channel that is down stays down, which is what exhausts a retry
    /// budget (round-16 QC).
    bool statusThrows = false;

    setUp(() async {
      status = _statusObtained;
      canRequestAds = true;
      privacyOptionsRequirement = _privacyOptionsNotRequired;
      privacyFormGate = null;
      statusGate = null;
    statusThrows = false;

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
          if (statusThrows) {
            return Future<int>.error(StateError('the consent channel is gone'));
          }
            final gate = statusGate;
            if (gate != null) return gate.future.then((_) => status);
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
      AdManager.debugResumeConsentRecheckTimeout = null;
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

    // Round-13 QC (BLOCKER) — end state alone is not enough: an App Open ad
    // filled under the old consent must not be on screen *before* the
    // withdrawal reaches the providers. The order is the compliance property.
    test('resume applies the pending withdrawal BEFORE any App Open work',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      final appOpen = adapter.calls.indexWhere((c) => c.contains('AppOpen'));
      expect(appOpen, greaterThanOrEqualTo(0),
          reason: 'the resume path must still reach the App Open ad — a '
              'consent re-check that swallows it would be its own bug');
      expect(adapter.calls.indexOf('applyConsent'), inInclusiveRange(0, appOpen),
          reason: 'the withdrawal must reach the provider before it is asked '
              'for an App Open ad, or a fill cached under the old consent '
              'shows first: ${adapter.calls}');
    });

    // Round-13 QC (MINOR) — `gdprApplies=0` makes tcfAllowsPersonalisedAds()
    // report *true* (out of scope, not "consented"). A backstop that trusted
    // that would flip a host's own deliberate refusal back on at every
    // resume, so it may only ever tighten.
    test('resume never overrides a host-set refusal outside GDPR scope',
        () async {
      seedTcf({'IABTCF_gdprApplies': 0});
      await AdManager().requestUmpConsent();

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));
      adapter.calls.clear();
      adapter.applied.clear();

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the host said no; a TCF "true" that only means "GDPR does '
              'not apply here" is not consent and must never grant');
      expect(adapter.applied, isEmpty,
          reason: 'and nothing should have been re-applied at all');
    });

    // Round-13 QC (round 2), BLOCKER — the resume gate is fail-closed: if the
    // consent re-check cannot settle, this resume does NO ad work at all
    // rather than risk a fill served under a consent the user has withdrawn.
    test('a resume consent re-check that never settles blocks all ad work',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      // The device now says refused, so the re-check goes on to ask UMP — and
      // that channel call is the one we wedge.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final wedge = Completer<void>();
      addTearDown(() {
        if (!wedge.isCompleted) wedge.complete();
      });
      statusGate = wedge;
      AdManager.debugResumeConsentRecheckTimeout =
          const Duration(milliseconds: 20);

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      // Real wall clock, so the timeout above actually fires — otherwise this
      // test would pass merely because the re-check is still hanging.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue(times: 50);

      expect(adapter.calls, isEmpty,
          reason: 'nothing that can request or show an ad may run while the '
              'consent state is unconfirmed — onAppResumed() recreates failed '
              'banners, so it counts too: ${adapter.calls}');
    });

    // Round-13 QC (round 2), MAJOR — the at-timeout snapshot is inconclusive
    // by construction (the form is still on screen), so it must not be
    // applied at all: applying it would grant personalisation back while the
    // user is still reading the form they opened to withdraw it.
    test('Privacy Options: the at-timeout snapshot is never applied', () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      // Whatever the host had applied before must survive the whole time the
      // form is up, even though the device state would say "granted".
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));
      debugFormDismissTimeoutOverride = const Duration(milliseconds: 20);
      final gate = Completer<void>();
      privacyFormGate = gate;

      await AdManager().showPrivacyOptions();
      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the user has not answered yet — reading the status while '
              'the form is up proves nothing and must not be applied');

      gate.complete();
      await pumpEventQueue(times: 50);
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'and once they do answer, that answer is applied');
    });

    // Round-13 QC (round 2), MAJOR — a decision made *after* an apply started
    // wins. The race lives in the few microtasks between an apply reading the
    // device state and writing it, so `debugConsentApplyBarrier` holds the
    // apply open there; nothing in the public API can hit that window.
    test('a host consent decision beats a consent apply already in flight',
        () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final barrier = Completer<void>();
      AdManager.debugConsentApplyBarrier = barrier.future;
      addTearDown(() {
        AdManager.debugConsentApplyBarrier = null;
        if (!barrier.isCompleted) barrier.complete();
      });

      // Starts an apply that would write hasUserConsent=false, and parks it.
      final pending = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // The host decides afterwards — a parental toggle, a CCPA switch.
      AdManager.debugConsentApplyBarrier = null;
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      barrier.complete();
      await pending;
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'the host spoke last, so the parked apply must drop itself '
              'instead of writing the value it read before that');
    });

    // Round-13 QC (round 2), MAJOR — the late apply runs with nobody awaiting
    // it, so a throw inside it used to become an unhandled zone error (which
    // in a host app means a crash report, and in this suite a failed test).
    test('a throwing late apply is logged, not an unhandled zone error',
        () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      debugFormDismissTimeoutOverride = const Duration(milliseconds: 20);
      final gate = Completer<void>();
      privacyFormGate = gate;
      final atTimeout = await AdManager().showPrivacyOptions();
      expect(atTimeout.error, contains('timed out'), reason: 'sanity');

      // The apply fails once the late dismiss has entered it. The error is
      // raised through a completer, not `Future.error`, so the failure belongs
      // to the apply rather than to this test's own unawaited future.
      final failure = Completer<void>();
      AdManager.debugConsentApplyBarrier = failure.future;
      addTearDown(() => AdManager.debugConsentApplyBarrier = null);
      gate.complete();
      await pumpEventQueue(times: 20);
      failure.completeError(StateError('storage is gone'));
      await pumpEventQueue(times: 50);

      // Reaching here at all is the assertion: an unhandled async error in
      // this window fails the test outright.
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'and a failed apply leaves the last good value in place');
    });

    // Round-13 QC (round 3), BLOCKER — the end state is not the whole story:
    // a superseded apply that opens the ad gate before it drops itself lets an
    // ad be requested under a consent that is already invalid, even though the
    // consent value itself ends up correct.
    test('a superseded apply never opens the ad gate on its way out', () async {
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      final barrier = Completer<void>();
      AdManager.debugConsentApplyBarrier = barrier.future;
      addTearDown(() {
        AdManager.debugConsentApplyBarrier = null;
        if (!barrier.isCompleted) barrier.complete();
      });
      final pending = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // Something newer invalidates that apply while it is parked.
      AdManager.debugConsentApplyBarrier = null;
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));

      barrier.complete();
      await pending;
      await pumpEventQueue(times: 50);

      expect(AdManager().canRequestAds, isFalse,
          reason: 'the gate must stay shut — an apply that is about to drop '
              'itself must not let an ad request through first');
    });

    // Round-13 QC (round 3), MAJOR — the window also covers the write itself:
    // a host decision that lands while the apply is writing is newer, and the
    // apply must not be the last writer standing.
    test('a host decision landing mid-write is restored over the apply',
        () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final writeBarrier = Completer<void>();
      AdManager.debugConsentWriteBarrier = writeBarrier.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!writeBarrier.isCompleted) writeBarrier.complete();
      });

      final pending = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // The host speaks while the apply is parked on the write itself.
      AdManager.debugConsentWriteBarrier = null;
      await AdManager().setConsent(const AdConsent(
        hasUserConsent: true,
        doNotSell: true,
      ));

      writeBarrier.complete();
      await pending;
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'the host wrote last in real time, so its value is what '
              'must be standing when the apply finishes');
      expect(AdManager().consent.doNotSell, isTrue,
          reason: 'and its other flags with it');
    });

    // Round-13 QC (round 4), MAJOR — the resume gate holds a reference to the
    // adapter across an await, and `destroy()` + re-initialise can swap it.
    test('a resume whose adapter was replaced mid-check touches neither',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      final old = _StubAdapter();
      AdManager().debugSetAdapter(old);
      AdManager().debugConfig = _config;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final wedge = Completer<void>();
      addTearDown(() {
        if (!wedge.isCompleted) wedge.complete();
      });
      statusGate = wedge;

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 10);

      // The session is torn down and re-initialised while the check hangs.
      final replacement = _StubAdapter();
      AdManager().debugSetAdapter(replacement);
      wedge.complete();
      await pumpEventQueue(times: 50);

      expect(old.calls, isEmpty,
          reason: 'the replaced adapter is disposed — driving its native '
              'channel could recreate ads on a dead session: ${old.calls}');
      // The consent write itself legitimately reaches whoever is current; what
      // must not happen is ad work for a resume this adapter never saw.
      expect(replacement.calls.where((c) => c != 'applyConsent'), isEmpty,
          reason: 'and the new adapter gets its own resume, not this one: '
              '${replacement.calls}');
    });

    // Round-13 QC (round 4), MAJOR — a consent write still hanging at teardown
    // must not lock the next session out of applying consent at all.
    test('a write hanging at destroy() does not wedge the next session',
        () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue, reason: 'sanity');

      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final wedged = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      await AdManager().destroy();

      // New session: the user withdraws, and that has to actually apply.
      AdManager.debugConsentWriteBarrier = null;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 20);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'a write left hanging by the previous session must not make '
              'every later withdrawal a no-op');

      stuck.complete();
      await wedged;
    });

    // Round-13 QC (round 5), MAJOR — the loop `destroy()` disowned must not
    // release the runner while a newer loop holds it, or two applies write
    // concurrently and the older decision can land last.
    test('a disowned apply loop cannot hand the runner to a second one',
        () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      final stuck1 = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck1.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck1.isCompleted) stuck1.complete();
      });
      final orphan = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().destroy();

      // New session, newer decision: a withdrawal, which owns the runner.
      final stuck2 = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck2.future;
      addTearDown(() {
        if (!stuck2.isCompleted) stuck2.complete();
      });
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final withdrawal = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // The disowned loop finishes here — its `finally` runs.
      stuck1.complete();
      await orphan;
      await pumpEventQueue(times: 10);

      // Newest decision of all: a re-grant, with nothing holding it back.
      AdManager.debugConsentWriteBarrier = null;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final regrant = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      stuck2.complete();
      await withdrawal;
      await regrant;
      await pumpEventQueue(times: 20);

      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'the newest decision has to be the last write — a second '
              'loop running alongside the first lets the older withdrawal '
              'land after the re-grant');
    });

    // Round-13 QC (round 6), MAJOR — while a permissive write is still in
    // flight the gate must stay shut, or an ad can be requested under a
    // consent a newer host decision is about to overwrite.
    test('the ad gate stays shut until a permissive write has landed',
        () async {
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;

      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final pending = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      expect(AdManager().canRequestAds, isFalse,
          reason: 'the grant has not reached the providers yet — requesting an '
              'ad now would run under a consent still in flight');

      stuck.complete();
      await pending;
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isTrue,
          reason: 'and once it lands the gate does open');
    });

    // Round-13 QC (round 7), MAJOR — a form opened before `destroy()` can
    // report back long after a new session has made its own decision.
    test('a form from a torn-down session never writes into the new one',
        () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      debugFormDismissTimeoutOverride = const Duration(milliseconds: 20);
      final gate = Completer<void>();
      privacyFormGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      // Returns the (inconclusive) at-timeout snapshot with the form still up.
      await AdManager().showPrivacyOptions();

      await AdManager().destroy();

      // The new session's own decision: a host-side refusal, which the TCF
      // keys do not contradict (a parental toggle, a CCPA choice).
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));
      expect(AdManager().consent.hasUserConsent, isFalse, reason: 'sanity');

      // Only now does the old form report back.
      gate.complete();
      await pumpEventQueue(times: 30);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the answer to a form the previous session opened must not '
              'overwrite the decision this one made');
    });

    // Round-13 QC (round 8), BLOCKER — `destroy()` does not dismiss the native
    // form, so the answer arriving from it can be a real withdrawal the user
    // made while the *new* session was already serving ads. Dropping it
    // outright would leave personalised ads running against the user's choice.
    test('a withdrawal made in a pre-teardown form still reaches the new '
        'session', () async {
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      debugFormDismissTimeoutOverride = const Duration(milliseconds: 20);
      final gate = Completer<void>();
      privacyFormGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await AdManager().showPrivacyOptions();

      await AdManager().destroy();

      // New session, ads running under a grant.
      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue, reason: 'sanity');

      // The user withdraws in the form the old session opened. The CMP writes
      // it to the TCF keys whatever our session bookkeeping says.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      gate.complete();
      await pumpEventQueue(times: 40);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the session changed, but the withdrawal is the user’s and '
              'the device records it — it must be honoured');
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'and the provider must be told, not just our cache');
    });

    // Round-13 QC (round 9), MAJOR — a queued restrictive intent must not wait
    // for the runner to reach it before the gate closes, and the apply in
    // flight must not open the gate over the top of it.
    test('an apply in flight never opens the gate over a queued refusal',
        () async {
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');

      privacyOptionsRequirement = _privacyOptionsRequired;
      final stuck1 = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck1.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck1.isCompleted) stuck1.complete();
      });
      // A grant takes the runner and parks at its write.
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final grant = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // A refusal lands behind it. It parks at the apply *entry* barrier, so
      // it cannot tighten the gate itself — that is what leaves the older
      // grant's open gate observable at all.
      final stuck2 = Completer<void>();
      AdManager.debugConsentApplyBarrier = stuck2.future;
      addTearDown(() {
        AdManager.debugConsentApplyBarrier = null;
        if (!stuck2.isCompleted) stuck2.complete();
      });
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final refusal = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'queueing a refusal has to shut the gate immediately');

      // Not awaited yet: the call that owns the runner drains the whole queue,
      // so `grant` only completes once the refusal has been through too.
      stuck1.complete();
      await pumpEventQueue(times: 10);

      expect(AdManager().canRequestAds, isFalse,
          reason: 'the older grant finished writing, but a refusal is queued '
              'behind it — the form is already gone, so an open gate here is '
              'an ad served under a superseded consent');

      stuck2.complete();
      await grant;
      await refusal;
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse, reason: 'and it stays shut');
    });

    // Round-13 QC (round 10), BLOCKER — the realistic withdrawal never trips
    // `canRequestAds` at all: turning personalisation off in the CMP form
    // still leaves non-personalised ads servable, so UMP keeps saying
    // `canRequestAds=true` and only the TCF purposes change. The gate
    // therefore stayed open for the whole provider + storage write while the
    // OLD personalised configuration was still applied to AdMob/AppLovin.
    test('a personalisation withdrawal shuts the gate until the write lands',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'sanity: personalised ads are what is applied right now');
      expect(AdManager().canRequestAds, isTrue, reason: 'sanity: gate open');

      privacyOptionsRequirement = _privacyOptionsRequired;
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      // The withdrawal: purposes refused, but UMP still reports it can
      // request ads, because it still can — just not personalised ones.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final withdrawal = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      expect(AdManager().canRequestAds, isFalse,
          reason: 'the provider still has hasUserConsent=true applied, so any '
              'load accepted in this window is a personalised ad served '
              'after an explicit withdrawal');

      stuck.complete();
      await withdrawal;
      await pumpEventQueue(times: 10);

      expect(AdManager().consent.hasUserConsent, isFalse);
      expect(AdManager().canRequestAds, isTrue,
          reason: 'once the non-personalised config has landed the gate must '
              'reopen — withdrawing personalisation is not withdrawing ads');
    });

    // Round-13 QC (round 11), BLOCKER — the two races above, combined. A
    // purposes-only withdrawal reports `canRequestAds=true`, so round-9's
    // queue-time tighten (which reads that flag) does nothing for it, and
    // round-10's tighten only runs once the runner reaches this result — which
    // it cannot while an earlier apply is still in provider/storage I/O. The
    // gate therefore stayed open over that whole window with the OLD
    // personalised configuration applied.
    test('a purposes-only withdrawal queued behind a running apply shuts the '
        'gate at queue time', () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'sanity: personalised is what the provider has applied');
      expect(AdManager().canRequestAds, isTrue, reason: 'sanity: gate open');

      privacyOptionsRequirement = _privacyOptionsRequired;

      // An apply that changes nothing takes the runner and parks at its write
      // — a slow provider call or a slow storage write, which is all it takes.
      final stuck1 = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck1.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck1.isCompleted) stuck1.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // Now the withdrawal, queued behind it. UMP still says it can request
      // ads — only the purposes changed — and it is parked at the apply entry
      // barrier, so nothing inside the runner can tighten on its behalf.
      final stuck2 = Completer<void>();
      AdManager.debugConsentApplyBarrier = stuck2.future;
      addTearDown(() {
        AdManager.debugConsentApplyBarrier = null;
        if (!stuck2.isCompleted) stuck2.complete();
      });
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final withdrawal = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      expect(AdManager().canRequestAds, isFalse,
          reason: 'the withdrawal is queued and the provider still holds the '
              'personalised config — an open gate here is a personalised ad '
              'requested after the user turned personalisation off');

      stuck1.complete();
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'the first apply finished writing, but the withdrawal it is '
              'holding up has still not been applied');

      stuck2.complete();
      await first;
      await withdrawal;
      await pumpEventQueue(times: 10);
      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the withdrawal reached the provider');
      expect(AdManager().canRequestAds, isTrue,
          reason: 'and once it has, non-personalised ads are allowed again — '
              'the pessimistic close must not be permanent');
    });

    // The other half of the round-11 close: a queued *grant* must not be
    // stranded by it. Nothing reopens a pessimistically shut gate except the
    // runner, so if the runner ever fails to, every consenting user loses
    // their ads for the rest of the session.
    test('a grant queued behind a running apply still reopens the gate',
        () async {
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');

      privacyOptionsRequirement = _privacyOptionsRequired;
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final grant = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      stuck.complete();
      await first;
      await grant;
      await pumpEventQueue(times: 10);

      expect(AdManager().consent.hasUserConsent, isTrue);
      expect(AdManager().canRequestAds, isTrue,
          reason: 'the queued grant was applied, so the gate must be open — a '
              'pessimistic close nobody lifts is an outage, not a fix');
    });

    // Round-13 QC (round 12), MAJOR — the round-11 close is a guess, and a
    // guess needs an owner. Both reviewers found the same hole from opposite
    // ends: the apply that was supposed to lift it can end without writing
    // anything (superseded by a host `setConsent`) or die on the way (its write
    // throws). Nothing else in the SDK reopens the gate — `setConsent`
    // deliberately does not — so the app went dark for the rest of the session.
    test('a pessimistic close is lifted when the apply that owed it was '
        'superseded', () async {
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // A grant queued behind it — the round-11 close.
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: round 11 shuts the gate for a queued result');

      // The host now makes its own decision, which supersedes both applies:
      // their values are dropped, so neither ever reopens the gate.
      AdManager.debugConsentWriteBarrier = null;
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 50);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'UMP allows ads and what is applied matches the device — a '
              'gate left shut here is every ad surface in the app dark for '
              'the rest of the session');
    });

    test('a pessimistic close is lifted when the apply that owed it failed',
        () async {
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      // The write itself fails — a storage error, a dead platform channel.
      final failing = Completer<void>();
      AdManager.debugConsentWriteBarrier = failing.future;
      addTearDown(() => AdManager.debugConsentWriteBarrier = null);
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: round 11');

      // The queued grant must still get its turn once the first apply dies.
      AdManager.debugConsentWriteBarrier = null;
      failing.completeError(StateError('storage is gone'));
      await expectLater(first, throwsA(isA<StateError>()),
          reason: 'the caller is still told its apply failed');
      await queued;
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'the queued grant was applied — a failing apply must not '
              'take the intents behind it down with it');
      expect(AdManager().canRequestAds, isTrue);
    });

    // Round-13 QC (round 13), BLOCKER — the recovery has awaits of its own,
    // and a real consent decision can start inside any of them. It must lose
    // to that decision: reopening the gate while a withdrawal is mid-apply is
    // a personalised ad served under the old configuration, which is the whole
    // thing rounds 9-12 exist to prevent.
    test('recovery never reopens the gate over an apply that started while it '
        'was waiting', () async {
      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      // Arm the debt: an apply parked at its write, a second one queued behind
      // it (round 11 shuts the gate), then a host decision supersedes both.
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity: round 11');

      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      // Wedge the UMP status call so the recovery parks inside itself.
      final wedge = Completer<void>();
      statusGate = wedge;
      addTearDown(() {
        statusGate = null;
        if (!wedge.isCompleted) wedge.complete();
      });
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 10);

      // While the recovery is parked, the user withdraws personalisation. The
      // apply is held at its ENTRY barrier, so it has not read the TCF keys
      // yet — which is exactly the shape of the race: the recovery's own TCF
      // read still returns the permissive snapshot, and what is applied still
      // matches it, so nothing in its own snapshot says to stop.
      final withdrawalEntry = Completer<void>();
      AdManager.debugConsentApplyBarrier = withdrawalEntry.future;
      addTearDown(() {
        AdManager.debugConsentApplyBarrier = null;
        if (!withdrawalEntry.isCompleted) withdrawalEntry.complete();
      });
      final withdrawal = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      wedge.complete();
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isFalse,
          reason: 'an apply is in flight — it, not this recovery, owns the '
              'gate. Reopening here lets an ad be requested against a '
              'configuration that is about to change');

      // And the withdrawal decides, as it should.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      withdrawalEntry.complete();
      await withdrawal;
      await pumpEventQueue(times: 30);
      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'and the withdrawal is what ends up applied');
    });

    // Round-13 QC (round 13), MAJOR — the recovery was one-shot. A transient
    // channel failure (or a native side that never answers) left the debt
    // armed with nothing coming back for it, which is the same session-long
    // ad outage the recovery was added to prevent.
    test('recovery retries when the UMP channel fails', () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      // The recovery's UMP read fails the first time it is tried.
      final broken = Completer<void>();
      statusGate = broken;
      addTearDown(() => statusGate = null);
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 10);
      broken.completeError(StateError('the consent channel is gone'));
      await pumpEventQueue(times: 20);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: nothing could be confirmed, so nothing is reopened');

      // The channel comes back. The retry must find it.
      statusGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'a transient channel failure must not cost the session its '
              'ads — the debt has to be retried, not dropped');
    });

    // Round-14 QC, MAJOR — the recovery settled the debt flag on a UMP "no"
    // BEFORE re-checking that the debt was still its to settle. A stale "no"
    // landing after a newer apply had armed its own guessed close cleared that
    // apply's debt too, and nothing in the SDK reopens the gate on its own —
    // so when that newer apply then wrote nothing, every ad surface stayed
    // dark for the rest of the session.
    test('a stale UMP refusal never settles a debt a newer apply owns',
        () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      // Park the recovery inside its UMP read, and make the answer it is about
      // to get a refusal: `recheckUmpConsentStatus` reads canRequestAds first,
      // so this is the value that call has already captured.
      canRequestAds = false;
      final wedge = Completer<void>();
      statusGate = wedge;
      addTearDown(() {
        statusGate = null;
        if (!wedge.isCompleted) wedge.complete();
      });
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: the debt is armed and the recovery is parked');

      // A second decision starts underneath it and takes the gate over. From
      // here on it, not this parked recovery, is what decides. Its own flow
      // must not park on the same wedge, so the gate is dropped for new calls
      // — the recovery is already holding the future it got. And UMP is
      // permissive again: the refusal now belongs only to the answer the
      // recovery captured on its way in, which is what makes it stale.
      statusGate = null;
      canRequestAds = true;
      final entry = Completer<void>();
      AdManager.debugConsentApplyBarrier = entry.future;
      addTearDown(() {
        AdManager.debugConsentApplyBarrier = null;
        if (!entry.isCompleted) entry.complete();
      });
      final second = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);

      // The stale refusal finally lands.
      wedge.complete();
      await pumpEventQueue(times: 20);

      // The second apply is superseded, so it writes nothing at all: the debt
      // this recovery must not have cleared is the only thing left that can
      // reopen the gate.
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      entry.complete();
      await second;
      await pumpEventQueue(times: 30);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'a stale answer that clears someone else\'s debt strands '
              'the gate shut for the whole session');
    });

    // Round-14 QC, MAJOR — only the UMP read was retried. Everything after it
    // can fail too (the mismatch re-apply writes to both providers), and that
    // failure escaped into a detached logger: the debt stayed armed with
    // nobody coming back for it — the exact outage the recovery exists to
    // prevent.
    test('recovery retries when its own re-apply fails', () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      // Park the recovery, then make the device disagree with what is applied
      // so the recovery has to re-apply rather than just reopen…
      final wedge = Completer<void>();
      statusGate = wedge;
      addTearDown(() {
        statusGate = null;
        if (!wedge.isCompleted) wedge.complete();
      });
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 10);
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });

      // …and make that re-apply fail. Raised through a completer so the error
      // belongs to the apply, not to this test's own futures.
      final failure = Completer<void>();
      AdManager.debugConsentApplyBarrier = failure.future;
      addTearDown(() => AdManager.debugConsentApplyBarrier = null);
      wedge.complete();
      await pumpEventQueue(times: 20);
      failure.completeError(StateError('the provider write is gone'));
      await pumpEventQueue(times: 30);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: the write failed, so nothing may be reopened yet');

      // The next attempt gets through.
      AdManager.debugConsentApplyBarrier = null;
      statusGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'a failed recovery write must be retried like a failed UMP '
              'read — otherwise the session loses its ads either way');
      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'and it lands the device state, not the stale one');
    });

    // Round-15 QC, MAJOR — the recovery's own re-apply is an await too, and
    // the one it had no re-check after. A host decision landing while that
    // re-apply is in flight supersedes it, so it writes nothing — and the
    // recovery run it kicks on its way out is suppressed by
    // `_consentGateRecovering` while the outer run is still on the stack.
    // Nobody was left to reopen the gate.
    test('a host decision during the recovery\'s own re-apply does not strand '
        'the gate', () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      // Park the recovery, then make the device disagree with what is applied
      // so it has to re-apply rather than just reopen.
      final wedge = Completer<void>();
      statusGate = wedge;
      addTearDown(() {
        statusGate = null;
        if (!wedge.isCompleted) wedge.complete();
      });
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 10);
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });

      // Hold that re-apply at its entry, and let the host decide underneath it.
      final entry = Completer<void>();
      AdManager.debugConsentApplyBarrier = entry.future;
      addTearDown(() {
        AdManager.debugConsentApplyBarrier = null;
        if (!entry.isCompleted) entry.complete();
      });
      statusGate = null;
      wedge.complete();
      await pumpEventQueue(times: 20);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      AdManager.debugConsentApplyBarrier = null;
      entry.complete();
      await pumpEventQueue(times: 30);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: the re-apply was superseded, so it wrote nothing');

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'the run that was supposed to pay the debt cannot leave '
              'without arming a retry — its own nested kick is suppressed '
              'while it is still on the stack');
    });

    // Round-14 QC, MINOR — the ordinary apply refills the held fullscreen
    // slots when it reopens the gate. Recovery reopens the same gate, so it
    // owed the same refill: without it the app-open, interstitial and rewarded
    // slots stay empty until a route change or the 5-minute scan, i.e. the
    // user's next ad simply does not exist.
    test('recovery refills the held fullscreen slots when it reopens the gate',
        () async {
      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      addTearDown(() => AdManager().debugSetAdapter(null));

      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      adapter.calls.clear();

      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue, reason: 'sanity: reopened');
      expect(adapter.calls, contains('loadInterstitial'),
          reason: 'a reopened gate with nothing loaded behind it is the same '
              'blank screen to the user as a shut one');
    });

    // Round-14 QC, MAJOR — a host `setConsent` during one of the recovery's
    // awaits bumped the intent epoch, so the recovery stood down. But
    // `setConsent` deliberately never touches `_canRequestAds`, so nothing
    // took the debt over: the guessed close became permanent.
    test('a host consent decision mid-recovery does not strand the gate',
        () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        if (!stuck.isCompleted) stuck.complete();
      });
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      final wedge = Completer<void>();
      statusGate = wedge;
      addTearDown(() {
        statusGate = null;
        if (!wedge.isCompleted) wedge.complete();
      });
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 10);

      // The host toggles its own consent switch while the recovery is parked.
      // Nothing about that reopens the gate by itself.
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      wedge.complete();
      await pumpEventQueue(times: 20);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'the recovery has to hand the debt on when it loses its '
              'epoch — a settings toggle must not cost the session its ads');
    });

    // Round-16 QC, MAJOR — the three-attempt budget was session-global, not
    // per-debt. A debt that burned all three retries and was then settled by
    // an ordinary apply left the counter at 3, so the NEXT guessed close was
    // refused its very first retry: the gate stayed shut, and every ad surface
    // in the app stayed dark for the rest of the session.
    test('a second gate debt gets a retry budget of its own', () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);
      addTearDown(() {
        AdManager.debugConsentWriteBarrier = null;
        statusThrows = false;
        statusGate = null;
      });

      canRequestAds = false;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await AdManager().requestUmpConsent();

      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });

      // ── Debt #1: armed the usual way, then left to burn every retry it has
      // against a channel that never comes back. The failure is armed only
      // after both flows have read their status, so it hits the recovery and
      // not the forms.
      var stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      var first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      var queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      statusThrows = true;
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await pumpEventQueue(times: 20);
      }
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: the first debt used up its budget with the channel '
              'still dead');

      // ── The channel comes back and an ordinary decision settles debt #1 by
      // reopening the gate itself — which is exactly the path that used to
      // leave the burnt counter behind.
      statusThrows = false;
      await AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 20);
      expect(AdManager().canRequestAds, isTrue,
          reason: 'sanity: a clean apply settles the first debt');

      // ── Debt #2, armed identically, whose first recovery hits a transient
      // failure. One retry is all it needs.
      stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      // Armed only now: the forms above read the same channel, and a wedge set
      // any earlier would park them instead of the recovery.
      final broken = Completer<void>();
      statusGate = broken;
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      await pumpEventQueue(times: 10);
      broken.completeError(StateError('the consent channel is gone'));
      await pumpEventQueue(times: 20);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: nothing could be confirmed yet, so nothing opens');

      statusGate = null;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'a fresh guessed close owns a fresh budget — an older debt '
              'that gave up must not cost this one the session ads');
    });

    // Round-20 QC (codex), BLOCKER — the re-check reads the device, then waits
    // on UMP. A host `setConsent` that lands during that wait is the NEWER
    // decision, and the apply pipeline recomputes `hasUserConsent` from its own
    // fresh TCF read — so a re-apply queued from the stale device state used to
    // overwrite the host's own newer value. Capture the intent epoch before the
    // wait and stand down if it moved.
    test('a host consent decision landing mid-re-check is not overwritten',
        () async {
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      // The device says refused, so the re-check goes on to ask UMP — the call
      // we wedge, to hold it exactly in the window the race lives in.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final wedge = Completer<void>();
      addTearDown(() {
        if (!wedge.isCompleted) wedge.complete();
      });
      statusGate = wedge;

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 10);

      // The host speaks while the re-check is parked on UMP: a fresh grant,
      // newer than the device state the re-check read a moment ago.
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      wedge.complete();
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'the host wrote last in real time, so its value is what must '
              'be standing — a re-apply built from the device state read '
              'BEFORE it is stale by construction');
      expect(adapter.applied.last.hasUserConsent, isTrue,
          reason: 'and the providers must hold the same value, not the stale '
              'withdrawal: ${adapter.applied.map((c) => c.hasUserConsent)}');
    });

    // Round-20 QC (codex), BLOCKER — the withdrawal must not rest on the apply
    // pipeline's own second TCF read. `tcfAllowsPersonalisedAds()` returns null
    // for "no TCF data" (a storage error, or `gdprApplies` cleared under us),
    // and null means "assume allowed" there — so a re-apply carrying a
    // withdrawal came back out of the pipeline as a GRANT, leaving both
    // providers personalised under a refusal the device had already reported.
    test('a withdrawal survives a second TCF read that comes back empty',
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
      final wedge = Completer<void>();
      addTearDown(() {
        if (!wedge.isCompleted) wedge.complete();
      });
      statusGate = wedge;

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 10);

      // The TCF keys go away entirely between the read that found the refusal
      // and the pipeline's own read. UMP is still happy (`obtained`), so
      // nothing but the refusal we already read says "do not personalise".
      seedTcf({});
      wedge.complete();
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the refusal was read off the device before the re-apply was '
              'queued; a storage read failing afterwards cannot turn it back '
              'into consent');
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'and the provider must be reconfigured non-personalised: '
              '${adapter.applied.map((c) => c.hasUserConsent)}');
    });

    // Round-20 QC, BLOCKER — a tighten must never depend on the network.
    //
    // Both the resume backstop and the gate recovery read UMP FIRST and gave up
    // when it failed, so an offline device — or a UMP outage, which is a real
    // thing on hardware: `2:Error making request.`, reproduced on a Pixel 7 Pro
    // — kept the personalised configuration on both providers for the whole
    // session. Whether ads may be PERSONALISED is decided by the TCF purposes
    // alone; UMP only ever decides whether ads may be requested at all.
    test('a withdrawal is applied on resume even when UMP cannot be reached',
        () async {
      addTearDown(() => statusThrows = false);
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue, reason: 'sanity');

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;

      // The CMP records the withdrawal, and the network goes away before the
      // app is foregrounded again.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      statusThrows = true;

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the device is the record of what the user chose. A UMP that '
              'cannot be reached is no reason to keep serving personalised '
              'ads against a refusal for the rest of the session');
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'and the provider itself has to be told, not just our cache');
    });

    test('a gate debt whose UMP is unreachable still applies the device '
        'withdrawal', () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() {
        AdManager.debugConsentGateRecoveryRetryDelay = null;
        AdManager.debugConsentWriteBarrier = null;
        statusThrows = false;
      });

      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      privacyOptionsRequirement = _privacyOptionsRequired;

      // Arm the guessed close the same way the rounds above do: a second flow
      // queued behind a wedged write shuts the gate on a guess, and something
      // has to come back for it.
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      // The user withdrew in the form, and the channel the recovery would ask
      // is down. Armed only now so the forms above are not the ones that fail.
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      statusThrows = true;
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await pumpEventQueue(times: 20);
      }

      expect(adapter.applied, isNotEmpty,
          reason: 'the recovery is the path the init reconcile hands its '
              're-apply to — a UMP it cannot reach must not swallow the '
              'withdrawal with it');
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'personalisation off is exactly what the device reports, and '
              'it needs no second opinion to be applied');

      // ── And that apply must not swallow the debt on its way through. It
      // tightens the gate, every deliberate gate write clears the debt flag,
      // and nothing else in the SDK ever sets `canRequestAds` back to true — so
      // without a re-arm the app is left with the withdrawal correctly applied
      // and every ad surface dark for the rest of the session. Proven through
      // the reconnect, because by now the three bounded retries have burned
      // against the dead channel (that is the offline case: it lasts longer
      // than the retry budget).
      expect(AdManager().canRequestAds, isFalse, reason: 'sanity');
      statusThrows = false;
      AdManager().debugReconnectDebounce = const Duration(milliseconds: 20);
      addTearDown(() => AdManager().debugReconnectDebounce =
          const Duration(milliseconds: 800));
      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await pumpEventQueue(times: 20);
      }
      expect(AdManager().canRequestAds, isTrue,
          reason: 'personalisation off still allows non-personalised ads, and '
              'the close the tighten left behind still owed a reopen');
    });

    // Round-20 QC, MAJOR — the retry budget is three attempts. A debt that
    // burned all three while the device was offline had nobody left to pay it,
    // so the gate stayed shut for the rest of the session even once the network
    // was back and UMP was answering again.
    test('a reconnect pays a gate debt that gave up while offline', () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      AdManager().debugReconnectDebounce = const Duration(milliseconds: 20);
      addTearDown(() {
        AdManager.debugConsentGateRecoveryRetryDelay = null;
        AdManager().debugReconnectDebounce = const Duration(milliseconds: 800);
        AdManager.debugConsentWriteBarrier = null;
        statusThrows = false;
      });

      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      privacyOptionsRequirement = _privacyOptionsRequired;

      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      final first = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      final queued = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      statusThrows = true;
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await first;
      await queued;
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await pumpEventQueue(times: 20);
      }
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: every retry burned against a dead channel');

      // The network comes back. Nothing else in the SDK will ever set
      // `canRequestAds` true again on its own.
      statusThrows = false;
      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await pumpEventQueue(times: 20);
      }

      expect(AdManager().canRequestAds, isTrue,
          reason: 'the reconnect is the one event that says the read which '
              'failed can now succeed — without it every ad surface in the '
              'app stays dark for the rest of the session');
    });

    // Round-17 QC, MAJOR — a withdrawal that leaves ads ALLOWED closes the gate
    // for the duration of its write, and that close had no owner. When the
    // write was superseded by a host `setConsent`, the apply returned before
    // the reopen, `setConsent` deliberately never touches `_canRequestAds`, and
    // no debt was armed — so the gate stayed shut for the whole session.
    test('a withdrawal whose write is superseded still reopens the gate',
        () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);
      addTearDown(() => AdManager.debugConsentWriteBarrier = null);

      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().canRequestAds, isTrue, reason: 'sanity: granted');

      // The user turns personalisation off in the CMP form. Ads are still
      // allowed — the withdrawal shows up only in the TCF purposes.
      privacyOptionsRequirement = _privacyOptionsRequired;
      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      final apply = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: the gate is shut across the write, or a banner '
              'refresh in this window would request a personalised ad under a '
              'withdrawal');

      // A host settings toggle lands while the write is in flight, so the
      // apply restores the host value and returns without reopening.
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await apply;
      await pumpEventQueue(times: 30);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'personalisation off still allows non-personalised ads — a '
              'superseded write must not cost the app every ad surface for the '
              'rest of the session');
    });

    // Round-18 QC, BLOCKER — every other device-vs-applied comparison in this
    // file is tighten-only; the recovery's was not. A host
    // `setConsent(hasUserConsent: false)` — a parental toggle, a CCPA switch —
    // is a NEWER decision than whatever a CMP left in the TCF keys, so a
    // recovery that found those keys more permissive used to re-apply them
    // over the host's refusal and serve personalised ads against it.
    test('recovery never grants personalisation the host has switched off',
        () async {
      AdManager.debugConsentGateRecoveryRetryDelay =
          const Duration(milliseconds: 20);
      addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);
      addTearDown(() => AdManager.debugConsentWriteBarrier = null);

      canRequestAds = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'sanity: granted');

      // A withdrawal form shuts the gate for the duration of its write, which
      // is the debt the recovery exists to pay.
      privacyOptionsRequirement = _privacyOptionsRequired;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final stuck = Completer<void>();
      AdManager.debugConsentWriteBarrier = stuck.future;
      final apply = AdManager().showPrivacyOptions();
      await pumpEventQueue(times: 10);
      expect(AdManager().canRequestAds, isFalse,
          reason: 'sanity: the gate is shut across the write');

      // The host's own switch lands while that write is in flight, so it wins
      // and the apply returns without reopening — the debt stays armed.
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));
      // And by the time the recovery reads the device, the keys are permissive
      // again: the user re-consented in the CMP, or the app simply moved out
      // of scope (`gdprApplies=0`).
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      AdManager.debugConsentWriteBarrier = null;
      stuck.complete();
      await apply;
      await pumpEventQueue(times: 30);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue(times: 30);

      expect(AdManager().canRequestAds, isTrue,
          reason: 'non-personalised ads are still allowed, so the gate must '
              'not be left shut for the session');
      expect(AdManager().consent.hasUserConsent, isFalse,
          reason: 'the host switched personalisation off. A permissive device '
              'is never authority to grant — re-applying the CMP keys over '
              'that decision serves personalised ads against it');
    });

    // Round-18 QC, BLOCKER — a consent decision that cannot be PERSISTED must
    // still be APPLIED. `ConsentManager.set()` records in memory first,
    // persists second and only writes to the providers last, so a store that
    // refuses the write threw out of `setConsent` before either provider was
    // told: the SDK's record said "withdrawn", AdMob and AppLovin kept the
    // personalised configuration, and the host got an exception where it
    // expected enforcement.
    test('a withdrawal the store refuses to persist still reaches the '
        'providers', () async {
      final store = _FailableConsentStore();
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = store;
      AdPreferences.resetForTest();
      ConsentManager.resetForTest();
      addTearDown(ConsentManager.resetForTest);

      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final consentMgr = await ConsentManager.bootstrap(
          prefs: await AdPreferences.getInstance(),
          strings: ConsentDialogStrings.vi);
      final adapter = _StubAdapter();
      AdManager()
        ..debugConsentManager = consentMgr
        ..debugSetAdapter(adapter)
        ..debugConfig = _config;

      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      expect(adapter.applied.last.hasUserConsent, isTrue,
          reason: 'sanity: granted, and the write reached the provider');

      // The store starts refusing the consent key, and the user withdraws.
      store.failConsentWrite = true;
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));

      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'the withdrawal must reach the provider even when it cannot '
              'be saved. Serving personalised ads because a disk was full is '
              'the GDPR/DMA violation this test exists for');
    });

    // Round-18 QC, BLOCKER — and the other half: what the SDK has RECORDED is
    // not what is APPLIED. The built-in consent dialog writes through
    // `ConsentManager` directly, so a persist that throws there leaves the
    // record saying "withdrawn" with both providers still personalised. The
    // resume backstop compared the device against that record, found them in
    // agreement, and walked away — leaving the providers personalised under a
    // withdrawal for the rest of the session.
    test('a recorded-but-never-applied withdrawal is not mistaken for applied',
        () async {
      final store = _FailableConsentStore();
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = store;
      AdPreferences.resetForTest();
      ConsentManager.resetForTest();
      addTearDown(ConsentManager.resetForTest);

      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesAllow,
      });
      final consentMgr = await ConsentManager.bootstrap(
          prefs: await AdPreferences.getInstance(),
          strings: ConsentDialogStrings.vi);
      final adapter = _StubAdapter();
      AdManager()
        ..debugConsentManager = consentMgr
        ..debugSetAdapter(adapter)
        ..debugConfig = _config;

      await AdManager().setConsent(const AdConsent(hasUserConsent: true));
      expect(adapter.applied.last.hasUserConsent, isTrue,
          reason: 'sanity: granted, and the write reached the provider');

      // The dialog path: straight through ConsentManager, with the store
      // refusing the write, so it throws before touching either provider.
      store.failConsentWrite = true;
      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      await expectLater(
          consentMgr.set(
              const ConsentSettings(hasUserConsent: false, hasBeenAsked: true),
              config: _config),
          throwsA(isA<PlatformException>()));
      expect(consentMgr.adConsent.hasUserConsent, isFalse,
          reason: 'sanity: the SDK has already RECORDED the withdrawal');
      expect(adapter.applied.last.hasUserConsent, isTrue,
          reason: 'sanity: but nothing reached the provider — it is still '
              'configured for personalised ads');

      // The store heals (disk pressure passes) and the app comes back.
      store.failConsentWrite = false;
      final before = adapter.applied.length;
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(adapter.applied.length, greaterThan(before),
          reason: 'the record agreeing with the device proves nothing while '
              'the provider write never landed — the backstop must re-apply');
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'personalised ads under a withdrawal is the GDPR/DMA '
              'violation this test exists for');
    });

    // Round-19 QC, BLOCKER — round 18 tracked "what is really applied" inside
    // `AdManager.setConsent`, which is only ONE of the writers. The built-in
    // consent dialog writes through `ConsentManager` directly and
    // `initialize()` applies to the providers itself, so after either of those
    // the marker still described an older decision — and pointing every
    // device-vs-applied comparison at a stale marker is worse than the record
    // it replaced: a real withdrawal gets skipped as "already applied".
    test('a grant that did not come through setConsent still counts as applied',
        () async {
      SharedPreferences.setMockInitialValues({});
      AdPreferences.resetForTest();
      ConsentManager.resetForTest();
      addTearDown(ConsentManager.resetForTest);

      seedTcf({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': _purposesRefuse,
      });
      final consentMgr = await ConsentManager.bootstrap(
          prefs: await AdPreferences.getInstance(),
          strings: ConsentDialogStrings.vi);
      final adapter = _StubAdapter();
      AdManager()
        ..debugConsentManager = consentMgr
        ..debugSetAdapter(adapter)
        ..debugConfig = _config;

      // A host refusal goes through setConsent, so it is recorded as applied.
      await AdManager().setConsent(const AdConsent(hasUserConsent: false));
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'sanity: refused, and the write reached the provider');

      // The user then grants through the built-in consent dialog, which writes
      // straight through ConsentManager — the providers really are personalised
      // from here on, whatever anything else has cached.
      await consentMgr.set(
          const ConsentSettings(hasUserConsent: true, hasBeenAsked: true),
          config: _config);
      expect(await IabStorage.tcfAllowsPersonalisedAds(), isFalse,
          reason: 'sanity: the CMP keys were never touched by that dialog');

      // A resume now has to notice that the providers are personalised while
      // the device says no.
      final before = adapter.applied.length;
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(adapter.applied.length, greaterThan(before),
          reason: 'the grant landed on the providers, so the device refusing '
              'personalisation is a disagreement that must be re-applied');
      expect(adapter.applied.last.hasUserConsent, isFalse,
          reason: 'a marker that only tracks setConsent makes the backstop '
              'skip a real withdrawal as already-applied — personalised ads '
              'under a refusal, which is the violation this test exists for');
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
