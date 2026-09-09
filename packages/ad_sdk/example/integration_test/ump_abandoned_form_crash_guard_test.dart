// T149 — on-device proof that the periodic-backstop/reconnect
// abandoned-UMP-form recheck cannot crash the app with an unhandled zone
// error, using the SDK's own debug seams (debugUmpFormAbandoned,
// debugUmpAttemptFailed, debugForceAutoUmpError) to force the exact
// channel-throw condition deterministically — the real failure (a flaky UMP
// plugin channel) cannot be reproduced on demand otherwise. Same class of
// proof as test/ump_abandoned_form_zone_guard_test.dart, but exercised
// inside a real compiled app on a real device rather than the test harness.
//
// Run with:
//   flutter test integration_test/ump_abandoned_form_crash_guard_test.dart -d <device-or-sim-id>

import 'dart:async';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'reconnect and periodic-backstop abandoned-form rechecks do not '
      'crash the real app when the UMP channel throws', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // The reconnect/backstop UMP-retry branches this test targets both
    // require !_isVipMember — a fresh install's first-install VIP grace
    // (see CLAUDE.md) would otherwise short-circuit them before either
    // branch (including the one under test) is ever reached.
    await AdManager().vip?.revokeAll();

    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().debugReconnectDebounce = Duration.zero;
    // The real splash flow above already resolved a real (answered) UMP
    // result — force it back to "not yet answered" so the retry branches
    // (gated on !_umpAnswered) are reachable at all.
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().debugLastUmpResult = const UmpConsentResult(
        canRequestAds: false, status: ConsentStatus.required);
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().debugUmpAttemptFailed = true;
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().debugUmpFormAbandoned = true;
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().debugForceAutoUmpError =
        Exception('T149 on-device forced UMP channel error');
    addTearDown(() {
      // ignore: invalid_use_of_visible_for_testing_member
      AdManager().debugUmpAttemptFailed = false;
      // ignore: invalid_use_of_visible_for_testing_member
      AdManager().debugUmpFormAbandoned = false;
      // ignore: invalid_use_of_visible_for_testing_member
      AdManager().debugForceAutoUmpError = null;
      // ignore: invalid_use_of_visible_for_testing_member
      AdManager().debugLastUmpResult = null;
    });

    var zoneEscaped = false;
    Object? zoneError;
    await runZonedGuarded(() async {
      // ignore: invalid_use_of_visible_for_testing_member
      AdManager().debugConnectivityChanged(false);
      // ignore: invalid_use_of_visible_for_testing_member
      AdManager().debugConnectivityChanged(true); // reconnect path
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }, (e, st) {
      zoneEscaped = true;
      zoneError = e;
    });

    expect(zoneEscaped, isFalse,
        reason: 'the reconnect abandoned-form recheck must not escape as '
            'an unhandled zone error on a real device (saw: $zoneError)');
    expect(tester.takeException(), isNull,
        reason: 'and must not crash the widget tree either');
  });
}
