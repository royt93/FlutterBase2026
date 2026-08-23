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

    setUp(() async {
      status = _statusObtained;
      canRequestAds = true;
      privacyOptionsRequirement = _privacyOptionsNotRequired;
      privacyFormGate = null;
      statusGate = null;

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
