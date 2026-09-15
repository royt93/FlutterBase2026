// T201 on-device integration test — InlineAdController against the REAL
// app boot (real AdManager init, real — placeholder — ad units), covering
// the DoD's "scroll/background/consent" scenarios that a pure widget test
// can't: a real Navigator push/pop (proxy for "background/foreground"), a
// real scroll gesture, and a real AdManager().setConsent() withdrawal —
// none of which may silently override a controller-driven pause.
//
// Run with:
//   flutter test integration_test/t201_inline_ad_controller_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scroll_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'pausing the banner survives a scroll, a route push/pop, and a '
      'consent withdrawal — resume() reloads it back to active',
      (tester) async {
    app.main();
    await tester.pump();

    final home = find.text('ad_sdk demo');
    var reachedHome = false;
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (home.evaluate().isNotEmpty) {
        reachedHome = true;
        break;
      }
    }
    expect(reachedHome, isTrue,
        reason: 'splash must navigate to HomePage within ~45s');

    var initialised = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (AdManager().isInitialised) {
        initialised = true;
        break;
      }
    }
    expect(initialised, isTrue,
        reason: 'SDK must finish initialising before this is meaningful');

    final tile = find.text('Inline ad controller (T201)');
    await tester.scrollUntilVisibleAndSettle(tile, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(app.InlineAdControllerDemoPage), findsOneWidget);

    // Let the three sections' initial loads settle.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('status: active'), findsWidgets);

    // Pause the Banner section (the first one) — real dispose of a real
    // (possibly still-loading) AdMob/AppLovin banner instance.
    await tester.tap(find.text('Pause').first);
    await tester.pump();
    expect(find.text('status: paused'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Scroll: with a controller attached, VisibilityDetector's automatic
    // signal must not fight the controller's pause.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('status: paused'), findsOneWidget,
        reason: 'scrolling must not silently resume a controller-paused '
            'section');
    expect(tester.takeException(), isNull);

    // "Background/foreground" proxy: a real route push+pop on top of this
    // page — must not silently reload the paused banner either (T201's
    // didPopNext fix).
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('top'))));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('status: paused'), findsOneWidget,
        reason: 'a route round trip must not silently resume it');
    expect(tester.takeException(), isNull);

    // Consent withdrawal while paused must not silently reactivate it
    // either — _onPersonalisationWithdrawn (Banner/MREC) checks the same
    // _pausedByController gate.
    await AdManager().setConsent(const AdConsent(hasUserConsent: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('status: paused'), findsOneWidget,
        reason: 'withdrawing consent must not silently resume it either');
    expect(tester.takeException(), isNull);

    // Resuming must bring it back to active and reload.
    await tester.tap(find.text('Resume').first);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('status: active'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
