// On-device integration test for T157 — AdMob adaptive banner sizing.
//
// Boots the full example app, navigates to the dedicated "Banner adaptive
// sizing (T157)" demo (isolated from BannerDemoPage's other banner
// instances, which would all react to the dialog push too and muddy the
// comparison), opens the 220px-wide popup, and asserts:
//   1. no overflow/render exception (the pre-fix bug: a full-screen-sized
//      adaptive banner requested inside a 220px popup would overflow it)
//   2. the popup's own rendered width stays well under the full screen
//      width — nothing inside it forced the Dialog as wide as the screen.
//      (Not asserted to be exactly 220: Material's Dialog imposes its own
//      ~280px minimum-width floor regardless of its child's declared
//      width — a real, unrelated Flutter behavior, not a T157 bug. AdMob's
//      adaptive banner correctly follows THAT real constraint instead of
//      the screen, which is exactly what this task fixes.)
//
// Ad *content*/fill is never guaranteed (especially on a real device with no
// real inventory for the test ad unit), so this only asserts layout safety
// and no crash — not that a specific creative loaded.
//
// Run with:
//   flutter test integration_test/r157_banner_narrow_popup_test.dart \
//     -d <device-id> --dart-define=AD_PROVIDER_ADMOB=true

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

// A launch App Open ad can be showing full-screen right after init — the
// splash budget re-arms while it's in flight (see AdManager's own splash
// lifecycle log) — Home never becomes visible until it's actually gone.
Future<void> _waitForNotShowing(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final slot = AdManager().adapter?.appOpenSlot;
    if (slot == null || !slot.isShowing) return;
  }
  fail('app-open slot never left the showing state within 60s');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'banner inside a 220px popup does not overflow its container on a '
      'real device', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);
    await _waitForNotShowing(tester);

    final tile = find.text('Banner adaptive sizing (T157)');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the T157 demo tile');
    await tester.tap(tile);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Adaptive banner sizing (T157)'), findsOneWidget);

    final popupButton = find.text('Show banner in narrow popup');
    await tester.scrollUntilVisible(popupButton, 300);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(popupButton);
    // Banner has an auto-refresh timer — avoid pumpAndSettle. Give the
    // popup's banner a bounded window to measure its real container and
    // (re)load at the corrected width (T157's deferred first-load +
    // debounced correction both land within this window).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.text('220px-wide popup'), findsWidgets);
    expect(tester.takeException(), isNull,
        reason: 'T157 — a full-screen-sized adaptive banner request inside '
            'this 220px popup would overflow it and throw a layout '
            'exception here');

    final screenWidth = tester.view.physicalSize.width /
        tester.view.devicePixelRatio;
    final popupBox = tester.renderObject<RenderBox>(find.byWidgetPredicate(
        (w) => w is SizedBox && w.width != null && (w.width! - 220).abs() < 0.5));
    expect(popupBox.size.width, lessThan(screenWidth * 0.85),
        reason: 'T157 — the popup must stay a narrow dialog, nowhere near '
            'the full screen width ($screenWidth) — proves the banner '
            'inside it did not force it wider');
  });
}
