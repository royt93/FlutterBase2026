// On-device guard for the round-5 consent fixes (doc/audit/audit_claude.md
// MJ32/MJ33), driven by the example app's QA seam.
//
// Why this exists: outside the EEA, UMP resolves `notRequired` and never
// serves a form, so **every EEA-only code path stays unexercised** by the
// normal suite. That blind spot is what let two consent bugs ship past four
// audit rounds and ~890 green unit tests:
//   • the form was re-presented on every launch to a user who had already
//     answered (`isConsentFormAvailable()` means "a form exists", not
//     "consent is required"), and
//   • the dismiss timeout was 20 s, i.e. shorter than reading a real GDPR
//     form, so the flow resolved the ad gate before the user had chosen.
//
// KNOWN LIMITATION — read before trusting a green run: the UMP form is a
// *native* dialog, so `WidgetTester` cannot tap it. This test therefore
// cannot drive a consent decision itself. It asserts the invariant that is
// checkable without tapping:
//
//     status == obtained  =>  formShown == false
//
// which is exactly the MJ32 regression. To put a device into the `obtained`
// state, answer the form by hand ONCE:
//
//   1. adb shell pm clear <applicationId>          (or delete the app)
//   2. flutter run -d <id> --dart-define=UMP_EEA_DEBUG=true \
//                          --dart-define=UMP_TEST_ID=<hash>
//   3. tap "Consent" (or "Do not consent") on the form that appears
//
// From then on this test is a real regression guard on that device. It SKIPS
// (rather than fails) when the dart-defines are absent or when the device has
// not answered yet, so it is safe to leave in the suite — including on CI,
// where no test device hash is configured.
//
// `UMP_TEST_ID` is the hashed device id UMP prints to the log on first run:
//   I/UserMessagingPlatform: Use new ConsentDebugSettings.Builder()
//       .addTestDeviceHashedId("XXXXXXXX...") to set this as a debug device.
//
// Run with:
//   flutter test integration_test/ump_eea_consent_test.dart -d <device-id> \
//     --dart-define=UMP_EEA_DEBUG=true --dart-define=UMP_TEST_ID=<hash>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const bool _eeaDebug = bool.fromEnvironment('UMP_EEA_DEBUG');
const String _testId = String.fromEnvironment('UMP_TEST_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an already-answered EEA user is never re-shown the consent form',
    (tester) async {
      // `skip:` on testWidgets only takes a bool, so the reason is surfaced
      // via markTestSkipped instead — a silent skip is worse than no test.
      if (!_eeaDebug || _testId.isEmpty) {
        markTestSkipped(
          'needs --dart-define=UMP_EEA_DEBUG=true and '
          '--dart-define=UMP_TEST_ID=<hashed device id>; see file header',
        );
        return;
      }

      // Deliberately does NOT boot the example app: this exercises the UMP
      // flow directly, so a form (if one were wrongly presented) cannot be
      // hidden behind the splash's own 8 s hard cap.
      final r = await AdManager().requestUmpConsent(
        testMode: true,
        debugGeography: DebugGeography.debugGeographyEea,
        testIdentifiers: <String>[_testId],
      );

      // Guards the QA seam itself: if debugGeography silently stops taking
      // effect (wrong hash, seam removed, plugin change), the whole EEA path
      // goes back to being untested — and it would do so *quietly*, which is
      // the failure mode that hid MJ32. `notRequired` here means the device
      // is not being treated as EEA at all.
      expect(
        r.status,
        isNot(ConsentStatus.notRequired),
        reason: 'debugGeography did not take effect — check UMP_TEST_ID '
            'matches this device\'s hashed id (UMP logs it on first run). '
            'Without it this test proves nothing.',
      );

      if (r.status != ConsentStatus.obtained) {
        markTestSkipped(
          'device has not answered the consent form yet (status='
          '${r.status.name}) — answer it once by hand, see this file\'s '
          'header. Skipping rather than asserting on a state we cannot '
          'reach without tapping a native dialog.',
        );
        return;
      }

      // The MJ32 regression, stated directly.
      expect(
        r.formShown,
        isFalse,
        reason: 'consent is already obtained, so no form should have been '
            'presented. formShown==true here means an EEA user is being '
            'asked again on every single launch.',
      );

      // MJ33: with consent obtained the flow must not go anywhere near the
      // form-dismiss timeout — it should not even ask UMP to present one.
      expect(r.error, isNull,
          reason: 'a timeout/error on the already-answered path means the '
              'flow is still presenting (or waiting on) a form');
      expect(r.canRequestAds, isTrue,
          reason: 'consent obtained must leave the ad gate open');
    },
  );
}
