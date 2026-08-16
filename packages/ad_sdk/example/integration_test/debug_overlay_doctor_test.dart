// On-device integration test for DebugAdOverlay's "integration doctor"
// button (T98) and the fill-rate baseline monitor's overlay row (T97).
//
// Neither is reachable via a plain `flutter test` widget test in a
// meaningful way: the doctor button calls runIntegrationSelfCheck(), which
// attempts REAL ad loads against the real AppLovin SDK — exactly the kind
// of native round trip this repo's integration_test/ suite exists for.
//
// Run with:
//   flutter test integration_test/debug_overlay_doctor_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// On a real iOS device the splash flow can hit BOTH the real ATT system
// prompt AND a real UMP consent form before initialize() ever completes —
// each has its own internal 20s timeout when nothing dismisses it headlessly
// (see AttConsent's `requestAttIfNeeded` / UmpConsent's dismiss-timeout log
// line), so worst case is ~40s of that alone before init even starts
// resolving. Budget well past that instead of the tighter 30s window other
// integration tests use (those don't always hit both prompts in sequence).
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
      'tapping the debug overlay pill, then "Run integration doctor", '
      'renders real pass/fail/skipped results without throwing',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final pill = find.text('🐛 Ad');
    expect(pill, findsOneWidget,
        reason: 'DebugAdOverlay must be mounted (kDebugMode) in the '
            'example app');
    await tester.tap(pill);
    await tester.pump(const Duration(milliseconds: 200));

    final doctorButton = find.text('🩺 Run integration doctor');
    expect(doctorButton, findsOneWidget);
    await tester.tap(doctorButton);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('🩺 Running doctor…'), findsOneWidget);

    // Per-slot load checks each wait up to their own default 15s timeout for
    // a real AdLoadEvent, and the demo app's AppLovin ad unit ids are
    // placeholders that never fill — so all 3 (interstitial/rewarded/app
    // open) genuinely pay their full timeout in sequence. Budget generously
    // past that (3 × 15s + slack) instead of guessing a shorter window.
    bool done = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('🩺 Running doctor…').evaluate().isEmpty) {
        done = true;
        break;
      }
    }
    expect(done, isTrue, reason: 'doctor run must finish within 60s');
    expect(tester.takeException(), isNull);

    // At least the always-present items must have rendered as real text
    // rows (exact pass/fail is environment-dependent — this is a smoke
    // test, not a re-assertion of integration_self_check_test.dart's unit
    // coverage).
    expect(find.textContaining('SDK initialised'), findsOneWidget);
    expect(find.textContaining('Navigator key wired'), findsOneWidget);
    expect(find.textContaining('Route observer wired'), findsOneWidget);
    expect(find.textContaining('ATT status readable'), findsOneWidget);
  });

  testWidgets(
      'enableFillRateBaselineMonitor persists real events to on-device '
      'SharedPreferences without throwing', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    await AdManager().enableFillRateBaselineMonitor();
    expect(AdManager().fillRateBaselineMonitor, isNotNull);

    AdManager().debugEmit(const AdLoadEvent(
      providerTag: '[smoke-test]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await tester.pump();

    // No baseline exists yet on a fresh install, so no alert is expected —
    // this only proves the real on-device SharedPreferences write path
    // (AdPreferences.recordFillRateBaselineSample) didn't throw.
    expect(tester.takeException(), isNull);
  });
}
