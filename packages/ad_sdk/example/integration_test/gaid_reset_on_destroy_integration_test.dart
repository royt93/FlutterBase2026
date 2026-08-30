// On-device integration test for Issue 3 — destroy()/_resetGuardState()
// must clear the stale GAID from the previous session; a device's ad ID
// surviving past the point the SDK claims to be torn down is a privacy
// leak. See ad_manager_core_test.dart (unit) and
// test_device_hash_demo_page_test.dart (widget) for the same contract
// proven against the debug seam / a mocked page rebuild.
//
// This drives the REAL app end to end: boots it (real GAID resolved via the
// real `advertising_id` plugin, not the debug seam), reads the GAID off the
// "AdMob test-device hash" demo page, calls the real AdManager().destroy(),
// then navigates back into the same page fresh and confirms it now shows
// the empty-state placeholder instead of the stale value.
//
// Run with:
//   flutter test integration_test/gaid_reset_on_destroy_integration_test.dart -d <device-or-sim-id>
//     --dart-define=AD_PROVIDER_ADMOB=true --dart-define=SKIP_SPLASH_AD=true
//
// SKIP_SPLASH_AD is not optional on a real device that actually gets ad fill.
// Without it the splash shows a real App Open ad, nothing in a scripted run
// can tap it closed, so the splash keeps re-arming ("splash budget elapsed but
// app-open in flight — re-arming +30s") and HomePage never appears inside the
// tile wait below. The failure then reads as "HomePage must list the AdMob
// test-device hash tile", which looks like a UI regression and is not one.
// Measured on a Pixel 7 Pro, 2026-08-26: red without the flag, green with it,
// no source change in between. The CI Android emulator does not need it (no
// App Open fill there), which is why the workflow omits it.

import 'dart:io' show Platform;

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Same ~40s-worst-case ATT+UMP splash budget documented in
// consent_dialog_test.dart's header.
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
      'GAID shown on the test-device hash page clears after a real '
      'destroy()', (tester) async {
    // Android-only by nature, and the reason is the point of the test rather
    // than an inconvenience. On Android the value under test is the GAID, which
    // the `advertising_id` plugin resolves without asking the user. iOS has no
    // GAID; its counterpart is the IDFA, which is empty unless the user has
    // ATT-authorised tracking — and no harness can tap a native ATT prompt, so
    // a scripted iOS run has nothing to clear and the "before" value is
    // legitimately ''. Asserting the teardown cleared it would then be
    // asserting nothing. `skip:` only takes a bool, so the reason is surfaced
    // through markTestSkipped, matching ump_eea_consent_test.dart.
    if (!Platform.isAndroid) {
      markTestSkipped(
        'GAID only exists on Android; on iOS the IDFA is empty without an '
        'ATT authorisation a scripted run cannot give, so there is nothing '
        'for destroy() to clear. See the note above.',
      );
      return;
    }

    // HomePage's demo list is viewport-lazy — see consent_dialog_test.dart /
    // consent_country_demo_test.dart for the same tall-synthetic-viewport
    // workaround.
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('AdMob test-device hash');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the AdMob test-device hash tile');

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('AdMob test-device hash'), findsWidgets);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();

    final gaidBefore = AdManager().currentDeviceGaid;
    expect(gaidBefore, isNotEmpty,
        reason: 'a real device must resolve a real GAID during init — if '
            'this is empty the rest of the assertion proves nothing');
    expect(find.text(gaidBefore), findsOneWidget,
        reason: 'the page must display the real, non-empty GAID before '
            'destroy()');

    await AdManager().destroy();
    expect(AdManager().currentDeviceGaid, isEmpty,
        reason: 'destroy() must clear the stale GAID immediately');

    // Navigate back to the same page fresh — MaterialApp/Navigator only
    // build a page widget once per push, so re-reading the field requires a
    // brand new route, not just another pump of the existing one.
    final backButton = find.byTooltip('Back');
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await tester.pump(const Duration(milliseconds: 300));
    }

    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    await tester.pump();
    await tester.tap(find.text('AdMob test-device hash'));
    await tester.pump(const Duration(milliseconds: 300));
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();

    expect(find.text('(empty — init not done yet, or LAT on)'),
        findsOneWidget,
        reason: 'a stale GAID surviving past a real destroy() would keep '
            'showing on this page as if the SDK still had it');
    expect(find.text(gaidBefore), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
