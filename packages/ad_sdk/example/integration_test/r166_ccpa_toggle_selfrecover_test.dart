// On-device integration test for T166 — CcpaOptOutToggle must self-recover
// (re-enable itself) once AdManager().initialize() finishes, if it was
// mounted before that point, without the host leaving and re-entering the
// screen.
//
// HomePage is only reachable AFTER the app's own splash flow (which is what
// actually calls AdManager().initialize()) has already fully completed —
// so navigating there via the T166 tile can never catch the "before init"
// race this fix is for; by the time Home exists, init is already done.
// Instead: `app.main()` mounts SplashScreen, whose OWN `initState` kicks off
// the real `AdManager().initialize()` in the background — this pushes
// `CcpaToggleDemoPage` directly onto that SAME real Navigator, ON TOP of
// splash, in the one to two frames right after app.main() before that
// initialize() future has any realistic chance of having resolved yet.
//
// Run with:
//   flutter test integration_test/r166_ccpa_toggle_selfrecover_test.dart \
//     -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a toggle pushed on top of splash before init finishes re-enables '
      'itself once init completes, without leaving the screen',
      (tester) async {
    app.main();
    // Deliberately minimal — enough for the very first frame (SplashScreen
    // mounted, its initState's AdManager().initialize() call fired and
    // returned a still-pending Future) without giving that real,
    // network-bound async chain any realistic chance to have resolved.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const app.CcpaToggleDemoPage()));
    // A route push transition needs a moment to actually finish building
    // the new page — a single zero-duration pump only starts it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(Switch), findsOneWidget,
        reason: 'the CCPA demo page must have been pushed and rendered');

    final caughtBeforeInit = !AdManager().isInitialised;
    // Printed (not just asserted) so a passing run is provably testing the
    // interesting case, not trivially passing because init happened to
    // already be done by the time this ran.
    // ignore: avoid_print
    print('T166 device test: caught before init finished = $caughtBeforeInit');
    if (caughtBeforeInit) {
      final initiallyDisabled =
          tester.widget<Switch>(find.byType(Switch)).onChanged == null;
      expect(initiallyDisabled, isTrue,
          reason: 'T166 — reached this page before init finished; the '
              'toggle must start disabled, not silently broken');
    }

    // Wait for real init to complete WHILE staying on this exact screen —
    // no navigation away and back.
    for (var i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (AdManager().isInitialised) break;
    }
    expect(AdManager().isInitialised, isTrue,
        reason: 'SDK must finish initialising on device');

    // One more pump for the toggle's own initRevision listener to react.
    await tester.pump(const Duration(milliseconds: 100));

    final s = tester.widget<Switch>(find.byType(Switch));
    expect(s.onChanged, isNotNull,
        reason: 'T166 — the toggle must have re-enabled itself once init '
            'finished, on the real device, without ever leaving this '
            'screen');
    expect(tester.takeException(), isNull);
  });
}
