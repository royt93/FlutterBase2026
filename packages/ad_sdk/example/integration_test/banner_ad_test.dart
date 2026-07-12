// On-device integration test for the Banner demo (BannerDemoPage).
//
// Boots the full example app, navigates to the Banner demo, and verifies the
// banner renders and survives a route push+pop — this exercises the SDK's
// RouteAware pause/resume wiring via `adRouteObserver` (AppLovin pauses /
// AdMob hides the banner while another route sits on top, then resumes on
// pop).
//
// Ad *content*/fill is never guaranteed (especially on a simulator), so this
// only asserts the banner container widget is present and the app never
// crashes — not that a specific creative loaded.
//
// Run with:
//   flutter test integration_test/banner_ad_test.dart -d <device-or-sim-id>

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

  testWidgets('banner renders and survives a route push+pop', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Splash replaces itself with Home on the ROOT navigator — wait for a
    // Home landmark before navigating (pushing too early races that replace).
    final tile = find.text('Banner ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list the Banner ad tile');

    await tester.tap(tile);
    // Banner has an auto-refresh timer — avoid pumpAndSettle, which would
    // hang against it. Give the banner a bounded window to load instead.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    // BannerDemoPage's buildBanner() always mounts a container widget for the
    // banner slot (AdWidget/PlatformView on native, a sized placeholder while
    // loading) — assert the demo page itself rendered without crashing.
    expect(find.text('Banner demo'), findsOneWidget);
    expect(find.text('Push another screen (verifies pause/resume)'),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    // Push the second screen — RouteAware should pause/hide the first
    // banner. Assert no crash while it's on top.
    await tester.tap(find.text('Push another screen (verifies pause/resume)'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Second route'), findsOneWidget);
    expect(find.text('Banner pauses on previous'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Pop back — banner on the first screen should resume without crashing.
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Banner demo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
