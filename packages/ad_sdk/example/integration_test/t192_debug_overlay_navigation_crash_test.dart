// T192 on-device integration test — the EXACT reported repro: open the
// example app, expand the debug overlay panel, then navigate to the
// "Banner ad" demo (whose initState() preloads an interstitial
// synchronously) — on a real device, through the real app boot, not a
// synthetic fixture.
//
// Run with:
//   flutter test integration_test/t192_debug_overlay_navigation_crash_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'expanding the debug overlay then navigating to Banner ad does not '
      'crash with "setState() or markNeedsBuild() called during build"',
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

    // Wait for the SDK to actually finish initialising — otherwise
    // BannerDemoPage's initState() preload call below hits the (harmless
    // but non-representative) "adapter null" early-return instead of
    // genuinely flipping interstitialSlot.state, which would make this
    // test pass trivially without ever exercising the vulnerable path.
    var initialised = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (AdManager().isInitialised) {
        initialised = true;
        break;
      }
    }
    expect(initialised, isTrue,
        reason: 'SDK must finish initialising before this repro is '
            'meaningful');

    // Expand the debug panel — subscribes DebugAdOverlay's ValueListenableBuilders.
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();
    expect(find.text('🐛 Ad SDK Debug'), findsOneWidget);

    // Navigate to the Banner ad demo — its initState() preloads an
    // interstitial synchronously (see BannerDemoPage), which is the exact
    // repro reported for this ticket.
    await tester.tap(find.text('Banner ad'));
    await tester.pump();

    expect(AdManager().adapter?.interstitialSlot.isLoading, isTrue,
        reason: 'confirms the preload call actually flipped the slot '
            'synchronously — otherwise the exception check below would '
            'pass trivially without exercising the vulnerable path');
    expect(tester.takeException(), isNull,
        reason: 'no FlutterError should have been thrown navigating away '
            'while the debug overlay panel is expanded');
  });
}
