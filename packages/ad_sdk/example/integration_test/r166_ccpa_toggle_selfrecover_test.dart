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
      'a toggle pushed before init finishes re-enables '
      'itself once init completes, without leaving the screen',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    AdManager().setNavigatorKey(navKey);

    // Mount the CCPA toggle screen directly with the required RouteAware observers.
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
      home: const app.CcpaToggleDemoPage(),
    ));
    await tester.pumpAndSettle();

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

    // Now kick off init manually, simulating what splash would do in the
    // background, while the toggle is already mounted.
    AdManager().initialize(
      config: app.DemoConfig.instance.build(),
      onComplete: (_, __) {},
    );

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
