// On-device integration test for T161 — requestAttIfNeeded() must not
// present Apple's native ATT prompt twice if called again before the first
// call resolves.
//
// Why on-device, and why this can't be a full "only one dialog visually
// appears" proof: there is no automated real-device UI-automation tool for
// iOS in this environment to tap a native system dialog (see
// att_consent.dart's own note on this, and `app_open_ad_test.dart`'s
// `_waitForNotShowing` comment for the same limitation on a different native
// dialog). ATT's own authorization status is also one-shot per real device
// per install (`notDetermined` only the very first time; every later call
// short-circuits with no prompt at all, by design), so a scripted run can't
// force a fresh prompt to actually appear.
//
// What this DOES prove, against the real `app_tracking_transparency` native
// plugin channel (not a Dart-level mock): calling requestAttIfNeeded() twice
// back-to-back, without awaiting the first, on the real device process
// resolves both calls with the exact same result and neither hangs — the
// two calls reached the SAME underlying native request rather than each
// independently reaching the plugin's requestAuthorization() channel call.
// Full branch coverage (both-set/error/timeout cases) lives in
// test/att_consent_test.dart.
//
// Run with:
//   flutter test integration_test/r161_att_duplicate_call_guard_test.dart \
//     -d <device-id>   (a REAL iPhone — ATT never prompts on Simulator)

import 'package:applovin_admob_sdk/src/core/att_consent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'two overlapping requestAttIfNeeded() calls against the real native '
      'plugin resolve with the same result and neither hangs', (tester) async {
    addTearDown(resetPendingAttRequest);

    final first = requestAttIfNeeded();
    // Fired immediately after, deliberately not awaiting the first — this
    // is exactly the "user double-tapped the permission button" scenario
    // the task describes.
    final second = requestAttIfNeeded();

    final results = await Future.wait([first, second]).timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail(
          'T161 — both calls must resolve well within ATT\'s own 20s '
          'internal timeout; a hang here means the guard is stuck'),
    );

    expect(results[0].status, results[1].status,
        reason: 'T161 — a second call joining the first in-flight request '
            'must resolve with the SAME status, proving it reached the '
            'same underlying native interaction rather than an '
            'independent one');
    expect(results[0].idfa, results[1].idfa);
  });
}
