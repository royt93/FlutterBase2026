// On-device integration test for the round-13 consent work — the on-resume
// backstop, which is the one piece of it that CANNOT be proven in
// `flutter test`.
//
// Why it exists: a CMP writes the user's answer into the IAB TCF keys the
// moment they submit the form, whether or not our dismiss callback ever
// arrives. The late-dismiss path covers the common case; this covers the ones
// where no callback comes at all (the form torn down by the OS, a plugin that
// drops the callback, the process resumed after the form was answered) — so a
// withdrawal can never survive as personalised ads for a whole session.
//
// Why on-device: the backstop reads the TCF keys out of the PLATFORM's own
// preference store — the Android default `<packageName>_preferences` file, and
// unprefixed keys on iOS — which is exactly the wiring that used to be broken
// while `setMockInitialValues` unit tests passed (MJ2/m10, round-5 audit).
// A mocked store proves the logic; only a device proves the plumbing.
//
// Unit coverage for the same contract:
//   test/tcf_personalisation_consent_test.dart
// Widget coverage for what the gate does to a mounted ad surface:
//   test/consent_gate_banner_widget_test.dart
//
// Run with:
//   flutter test integration_test/consent_resume_backstop_test.dart -d <device-or-sim-id>

import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Purposes 1, 3 and 4 — the personalised-advertising set — consented.
const String _purposesAllow = '1011000000';

/// The same user with purpose 4 ("use profiles to select personalised
/// advertising") refused. One missing purpose is enough.
const String _purposesRefuse = '1010000000';

/// Same config with the SDK's own UMP flow off — a host that gathers consent
/// itself. Round-17's init reconcile is the only thing left that can notice a
/// device/applied disagreement in such a session.
AdConfig _hostOwnedConsentConfig() => const AdConfig(
      provider: AdProvider.admob,
      autoRequestUmpConsent: false,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

AdConfig _admobConfig() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

/// Opens the very store a CMP writes to — the same one [IabStorage] reads.
Future<SharedPreferencesAsync> _tcfStore() async {
  if (Platform.isAndroid) {
    final pkg = (await PackageInfo.fromPlatform()).packageName;
    return SharedPreferencesAsync(
        options: IabStorage.androidOptionsFor('${pkg}_preferences'));
  }
  return SharedPreferencesAsync();
}

Future<void> _writeTcf(String purposes) async {
  final store = await _tcfStore();
  await store.setInt(IabStorage.keyGdprApplies, 1);
  await store.setString(IabStorage.keyPurposeConsents, purposes);
  // Drop IabStorage's cached handle so the next read cannot be served from
  // one opened before these writes.
  IabStorage.debugResetForTest();
}

Future<void> _clearTcf() async {
  final store = await _tcfStore();
  await store.remove(IabStorage.keyGdprApplies);
  await store.remove(IabStorage.keyPurposeConsents);
  IabStorage.debugResetForTest();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
    await _clearTcf();
  });

  testWidgets(
      'a TCF withdrawal this process never saw land is applied on the next '
      'resume', (tester) async {
    // The user consented, and that is what is applied to both providers.
    await _writeTcf(_purposesAllow);
    await AdManager().initialize(
      config: _admobConfig(),
      onComplete: (_, __) {},
    );
    await AdManager().requestUmpConsent();
    expect(await IabStorage.tcfAllowsPersonalisedAds(), isTrue,
        reason: 'sanity: the keys really did land in the platform store this '
            'device reads from — if this fails the plumbing is broken, not '
            'the backstop');
    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'sanity: a consenting user is applied as consenting');

    // Now the CMP writes a withdrawal that this process never hears about.
    await _writeTcf(_purposesRefuse);
    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'nothing has told the SDK yet — that is the whole problem');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    var withdrawn = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!AdManager().consent.hasUserConsent) {
        withdrawn = true;
        break;
      }
    }

    expect(withdrawn, isTrue,
        reason: 'the resume backstop must re-read the device consent state '
            'and stop personalised ads. Without it the withdrawal survives '
            'as personalised ads for the rest of the session');
  });

  // Round-17 QC, BLOCKER — a `destroy()` that interrupts a consent write
  // disowns that apply, and the guard reset reopens the ad gate (a stale close
  // would lock the next session out of ads for good). So the withdrawal that
  // never finished writing used to come back as personalised requests in the
  // next session. This is the device half: the TCF keys are read out of the
  // platform's own preference store, the plumbing a mocked store cannot prove.
  testWidgets('a withdrawal a teardown interrupted is reconciled at the next '
      'init', (tester) async {
    // Session 1: the user consented and that is what is applied. A host that
    // owns its consent flow states it BEFORE init — the order the README
    // requires, and the one that keeps this test independent of whether any
    // earlier test managed to reach UMP's servers.
    await _writeTcf(_purposesAllow);
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    await AdManager().initialize(
      config: _hostOwnedConsentConfig(),
      onComplete: (_, __) {},
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'sanity: a consenting user is applied as consenting');

    // The user withdraws, and the process goes down before the write lands.
    await AdManager().destroy();
    await _writeTcf(_purposesRefuse);

    // Session 2. Nothing here runs a UMP flow, so the init reconcile is the
    // only thing that can notice.
    await AdManager().initialize(
      config: _hostOwnedConsentConfig(),
      onComplete: (_, __) {},
    );

    var withdrawn = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!AdManager().consent.hasUserConsent) {
        withdrawn = true;
        break;
      }
    }

    expect(withdrawn, isTrue,
        reason: 'the interrupted withdrawal must be re-applied before this '
            'session requests anything — otherwise it survives as '
            'personalised ads for the whole session');
    // And the gate must not be left shut by the reconcile: personalisation off
    // still allows non-personalised ads.
    var reopened = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (AdManager().canRequestAds) {
        reopened = true;
        break;
      }
    }
    expect(reopened, isTrue,
        reason: 'a fail-closed reconcile owes a reopen — a withdrawal must not '
            'cost the app every ad surface for the session');
  });

  testWidgets('an init that agrees with the device changes nothing',
      (tester) async {
    // The other half: no needless re-apply, and no gate shut, on the ordinary
    // start where device and applied state already agree.
    await _writeTcf(_purposesAllow);
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    await AdManager().initialize(
      config: _hostOwnedConsentConfig(),
      onComplete: (_, __) {},
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(AdManager().consent.hasUserConsent, isTrue);
    expect(AdManager().canRequestAds, isTrue,
        reason: 'agreement means the reconcile has nothing to do, and it must '
            'never shut the gate on a healthy start');
  });

  // Round-18 QC, BLOCKER — the init reconcile compared device against applied
  // SYMMETRICALLY, and so did the recovery it hands the debt to. A host that
  // runs its own consent UI and starts a session with personalisation OFF on a
  // device whose TCF keys are permissive (a parental toggle, a CCPA switch, a
  // user who consented in the CMP and later turned it off in the app) got its
  // ad gate shut at launch, and the only thing that could reopen it re-applied
  // the permissive CMP keys over the host's stricter decision. Both directions
  // are wrong: either every ad surface stays dark for the session, or
  // personalised ads are served against a refusal.
  testWidgets('an init with the host stricter than the device keeps ads '
      'flowing without granting', (tester) async {
    // The host's own switch: personalisation off, ordinary ads still wanted,
    // stated before init like any host that owns its consent flow.
    await _writeTcf(_purposesAllow);
    await AdManager().setConsent(const AdConsent(hasUserConsent: false));
    await AdManager().initialize(
      config: _hostOwnedConsentConfig(),
      onComplete: (_, __) {},
    );
    await tester.pump(const Duration(milliseconds: 500));
    await AdManager().destroy();

    // Next session. The device keys are still permissive and nothing here runs
    // a UMP flow, so the init reconcile is the only thing that looks at them.
    await AdManager().setConsent(const AdConsent(hasUserConsent: false));
    await AdManager().initialize(
      config: _hostOwnedConsentConfig(),
      onComplete: (_, __) {},
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(AdManager().consent.hasUserConsent, isFalse,
        reason: 'a permissive device is never authority to grant. Re-applying '
            'the CMP keys over the host decision serves personalised ads '
            'against it');
    expect(AdManager().canRequestAds, isTrue,
        reason: 'personalisation off still allows non-personalised ads. '
            'Shutting the gate here left nothing that would reopen it, so '
            'every ad surface stayed dark for the whole session');
  });

  testWidgets('a resume with the device still consenting changes nothing',
      (tester) async {
    // The other half: the backstop must be silent on an ordinary resume, or
    // every consenting user pays for it with a needless re-apply on every
    // foreground — and a fail-closed gate must not shut on a healthy one.
    await _writeTcf(_purposesAllow);
    await AdManager().initialize(
      config: _admobConfig(),
      onComplete: (_, __) {},
    );
    await AdManager().requestUmpConsent();
    expect(AdManager().consent.hasUserConsent, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'agreement between device and applied state means the '
            'backstop has nothing to do');
    expect(AdManager().canRequestAds, isTrue,
        reason: 'and it must not shut the ad gate on a healthy resume');
  });
}
