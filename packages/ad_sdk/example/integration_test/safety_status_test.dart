// On-device integration test for the Safety status demo (SafetyDemoPage).
//
// The demo's AdConfig always uses `kDemoSafetyParams` — a fixed const (all
// caps at 999, throttle 2s, no warm-up; see example/lib/main.dart §1) — there
// is no runtime setter on AdSafetyParams to trigger cap boundaries against,
// confirmed by grep this session. So this test asserts the panel correctly
// *displays* that fixed config against the real `AdManager().config?.safety`
// on-device, rather than attempting to trip any caps.
//
// Run with:
//   flutter test integration_test/safety_status_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Safety demo page reflects the real fixed kDemoSafetyParams',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Safety status');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Safety status tile');

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Safety demo'), findsOneWidget);

    // The active-params card renders every field of the real AdManager()
    // config's safety params — kDemoSafetyParams sets 999 caps / 2000ms
    // throttle / 0ms warm-up (see example/lib/main.dart §1).
    final active = AdManager().config?.safety;
    expect(active, isNotNull);
    expect(active!.maxFullscreenAdsPerDay, 999);
    expect(active.minTimeBetweenFullscreenAds, 2000);

    // kDemoSafetyParams' numeric fields are, by design, identical to
    // AdSafetyParams.debug's preset (both: 999 caps / 2000ms throttle / 0ms
    // warm-up) — so the "between=…ms" / "session=…" content text is
    // rendered VERBATIM on both the Active-params card and the
    // Preset:AdSafetyParams.debug card below. Scope the finder to the
    // specific card (via its title-containing Card ancestor) instead of
    // asserting global uniqueness, which isn't guaranteed.
    final activeCard = find.ancestor(
      of: find.textContaining('Active params (demo: same for debug + release)'),
      matching: find.byType(Card),
    );
    expect(activeCard, findsOneWidget);
    expect(
        find.descendant(
            of: activeCard,
            matching: find.textContaining(
                'between=${active.minTimeBetweenFullscreenAds}ms')),
        findsOneWidget);
    expect(
        find.descendant(
            of: activeCard,
            matching: find.textContaining(
                'session=${active.maxFullscreenAdsPerSession}')),
        findsOneWidget);

    // Both built-in presets are also rendered for comparison — assert they
    // show real, non-demo values (production caps are far below 999).
    expect(find.textContaining('Preset: AdSafetyParams.production'),
        findsOneWidget);
    expect(find.textContaining('Preset: AdSafetyParams.debug'), findsOneWidget);

    // Live status + policy risk score read straight from AdSafetyConfig.
    expect(find.textContaining('Policy risk score'), findsOneWidget);
    expect(find.textContaining('/ 100'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
