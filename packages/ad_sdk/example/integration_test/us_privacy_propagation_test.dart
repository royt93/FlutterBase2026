// On-device integration test for round-25 QC round 21 — the CCPA / US-states
// sale opt-out reaching both providers.
//
// Why it exists: `IabStorage.usPrivacyOptedOut()` had parsed
// `IABUSPrivacy_String` since the round-5 audit and `AdManager` reported it, but
// `AdConsent.doNotSell` was writable by the host and by nothing else — so a user
// who opted out through a CMP still had AppLovin `setDoNotSell(false)` and AdMob
// `restricted_data_processing` unset. The SDK now reconciles the string at init
// and on every resume, tighten-only.
//
// Why on-device: the string is read out of the PLATFORM's own preference store —
// the Android default `<packageName>_preferences` file, unprefixed keys on iOS —
// which is exactly the wiring that was silently broken for the TCF keys while
// `setMockInitialValues` unit tests passed (MJ2/m10, round-5 audit). A mocked
// store proves the logic; only a device proves the plumbing.
//
// Unit coverage of the same contract, including every CONTROL:
//   test/consent_us_privacy_propagation_test.dart
//
// Run with:
//   flutter test integration_test/us_privacy_propagation_test.dart -d <device-id>

import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IAB US Privacy string, 4 characters: version, notice, **sale opt-out**,
/// LSPA. Index 2 is the one that decides.
const String _optedOut = '1YYN';
const String _notOptedOut = '1YNN';

AdConfig _config() => const AdConfig(
      provider: AdProvider.admob,
      // A host that owns its own consent flow: the reconcile is then the only
      // thing that can notice the device string, which is what is under test.
      autoRequestUmpConsent: false,
      // No App Open on resume. Two of these tests flip the app through
      // paused→resumed, and by then the App Open slot is filled: the SDK
      // would show a real full-screen ad, the engine would stop producing
      // frames, and `tester.pump` would never return (the run hung on
      // exactly that, twice). Nothing here is about App Open.
      appOpenTrigger: AppOpenTrigger.splashOnly,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

/// Opens the very store a CMP writes to — the same one [IabStorage] reads.
Future<SharedPreferencesAsync> _iabStore() async {
  if (Platform.isAndroid) {
    final pkg = (await PackageInfo.fromPlatform()).packageName;
    return SharedPreferencesAsync(
        options: IabStorage.androidOptionsFor('${pkg}_preferences'));
  }
  return SharedPreferencesAsync();
}

Future<void> _writeUsPrivacy(String value) async {
  final store = await _iabStore();
  await store.setString(IabStorage.keyUsPrivacy, value);
  // Drop IabStorage's cached handle so the next read cannot be served from one
  // opened before this write.
  IabStorage.debugResetForTest();
}

Future<void> _clearUsPrivacy() async {
  final store = await _iabStore();
  await store.remove(IabStorage.keyUsPrivacy);
  IabStorage.debugResetForTest();
}

/// Pumps until [test] holds or the budget runs out. The reconcile is async
/// (a platform store read, then a persist and a provider apply).
Future<bool> _pumpUntil(WidgetTester tester, bool Function() test) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (test()) return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Every test states its own starting point through the public API rather
  /// than scrubbing the device's preference file. On a real device
  /// `ConsentSettings` persists across tests AND across runs, so a CONTROL
  /// that merely *assumes* `doNotSell == false` quietly passes on the previous
  /// test's opt-out. A host intent is also the strongest baseline available:
  /// the reconcile is only ever allowed to tighten it, which is the rule under
  /// test.
  ///
  /// The earlier attempt — rewriting `ConsentSettings` in prefs and calling
  /// `ConsentManager.resetForTest()` between tests — disposed the very
  /// `ValueNotifier` the next reconcile writes to and wedged the run (three
  /// tests took 34 minutes, the fourth hit its timeout). Don't reintroduce it.
  Future<void> initWithBaseline({required bool doNotSell}) async {
    await AdManager()
        .setConsent(AdConsent(hasUserConsent: true, doNotSell: doNotSell));
    await AdManager().initialize(config: _config(), onComplete: (_, __) {});
  }

  tearDown(() async {
    await AdManager().destroy();
    await _clearUsPrivacy();
  });

  testWidgets('a sale opt-out already on disk is applied at init',
      (tester) async {
    await _writeUsPrivacy(_optedOut);
    expect(await IabStorage.usPrivacyOptedOut(), isTrue,
        reason: 'sanity: the string really did land in the platform store this '
            'device reads from — if this fails the plumbing is broken, not the '
            'reconcile');

    await initWithBaseline(doNotSell: false);

    expect(await _pumpUntil(tester, () => AdManager().consent.doNotSell), isTrue,
        reason: 'the user opted out of sale before this launch. Without the '
            'reconcile every request this session goes out with no CCPA '
            'signal on it');
  });

  testWidgets('an opt-out made while backgrounded is applied on resume',
      (tester) async {
    await _clearUsPrivacy();
    await initWithBaseline(doNotSell: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(AdManager().consent.doNotSell, isFalse, reason: 'sanity');

    // The user opens a CMP (or the OS privacy screen) and opts out while our
    // process is in the background. No callback of ours ever fires — the
    // string on disk is the only evidence.
    await _writeUsPrivacy(_optedOut);
    expect(AdManager().consent.doNotSell, isFalse,
        reason: 'nothing has told the SDK yet — that is the whole problem');

    // No pump between the two: while the app state is `paused` the scheduler
    // stops enabling frames, so a `pump` issued in that window can wait for a
    // frame that is never produced and hang the whole run. Nothing under test
    // needs time to pass while backgrounded.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(await _pumpUntil(tester, () => AdManager().consent.doNotSell), isTrue,
        reason: 'the resume reconcile must pick the opt-out up off the '
            'platform store; otherwise it survives as un-flagged requests for '
            'the rest of the session');
  });

  // CONTROL — the failure mode of an over-eager fix here is a revenue loss for
  // every US user, so the negative direction is pinned on the device too.
  testWidgets('CONTROL — a string that says "did not opt out" changes nothing',
      (tester) async {
    await _writeUsPrivacy(_notOptedOut);
    expect(await IabStorage.usPrivacyOptedOut(), isFalse, reason: 'sanity');

    await initWithBaseline(doNotSell: false);
    await tester.pump(const Duration(milliseconds: 1500));

    expect(AdManager().consent.doNotSell, isFalse,
        reason: 'index 2 is `N`. Reading that as an opt-out would cost every '
            'US user their personalised fill');
  });

  // CONTROL — tighten-only. The host's own switch is the newer, deliberate
  // decision and the device must never overrule it.
  testWidgets('CONTROL — the device never clears a doNotSell the host set',
      (tester) async {
    await _writeUsPrivacy(_notOptedOut);
    await initWithBaseline(doNotSell: true);
    await tester.pump(const Duration(milliseconds: 1500));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1500));

    expect(AdManager().consent.doNotSell, isTrue,
        reason: 'a host that opted the user out — a settings toggle, a '
            'purchase flow — must not be overruled by a negative device '
            'string');
  });
}
