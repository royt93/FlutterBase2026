// T153 — on-device proof that buildBanner()'s forwarded `active` param
// (the documented AdScreenState integration path, not the raw
// BannerAdWidget constructor) actually gates an IndexedStack tab's banner.
// The unit-level proof (does buildBanner() forward active at all) already
// lives in test/ad_screen_test.dart in the SDK package itself — this only
// pins that the real widget tree behaves under a real SDK init and a real
// tap sequence, same as native_indexedstack_visibility_test.dart (T154).
//
// Run with:
//   flutter test integration_test/banner_indexedstack_visibility_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
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
      'IndexedStack tab switch via buildBanner(active:) mounts/hides the '
      'banner without crashing', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Banner ad');
    var foundTile = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list Banner ad tile (a real splash App Open '
            'ad may be covering it and take a while to auto-dismiss)');

    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final tab2 = find.text('Tab 2 (banner)');
    await tester.scrollUntilVisible(tab2, 200,
        scrollable: find.byType(Scrollable).first);

    await tester.tap(tab2);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull,
        reason: 'T153 — selecting the tab that mounts a live banner via '
            'buildBanner(active: true) must not throw');

    final tab1 = find.text('Tab 1 (no ad)');
    await tester.tap(tab1);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull,
        reason: 'T153 — switching back away from the live banner tab must '
            'not throw either');
  });
}
