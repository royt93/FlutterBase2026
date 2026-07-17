// On-device integration test for the ad_sdk example app.
//
// Runs on a real device or simulator (the native AppLovin/AdMob plugins are
// only present there), NOT under headless `flutter test`. It boots the full
// example app and verifies the end-to-end native integration survives:
//   • app launches and renders the splash without crashing,
//   • the SDK initialises and the splash navigates to the demo HomePage,
//   • the public API surface is reachable post-init.
//
// Run with:
//   flutter test integration_test/app_boot_test.dart -d <device-or-sim-id>
//
// The assertions are intentionally lenient about ad *content* (fill is never
// guaranteed, especially on a simulator) — they only assert the app boots and
// the SDK reaches a healthy initialised state.

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('boots through splash to the demo home page', (tester) async {
    app.main();
    // The splash runs UMP/ATT + SDK init + an optional App Open buffer, so give
    // it a generous window. pumpAndSettle would hang on the banner auto-refresh
    // timer, so poll for the home page instead.
    await tester.pump();

    final home = find.text('ad_sdk demo');
    var found = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (home.evaluate().isNotEmpty) {
        found = true;
        break;
      }
    }

    expect(found, isTrue,
        reason: 'splash must navigate to HomePage within ~30s');
    expect(tester.takeException(), isNull,
        reason: 'no uncaught exception during boot + SDK init');
  });

  testWidgets('AdManager reports an initialised, healthy state after boot',
      (tester) async {
    app.main();
    await tester.pump();

    // Wait for init to complete.
    var initialised = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (AdManager().isInitialised) {
        initialised = true;
        break;
      }
    }

    expect(initialised, isTrue,
        reason: 'SDK must finish initialising on device');
    // VipManager is created during initialize(); a non-null vip surface proves
    // the entitlement subsystem wired up.
    expect(AdManager().vip, isNotNull);
    // The public API must be callable without throwing post-init.
    expect(() => AdManager().isVIPMember(), returnsNormally);
    expect(() => AdManager().canShowInterstitial(), returnsNormally);
  });

  // Reproduces, end-to-end on a real device/simulator, the original
  // production race: initialize() fires ad preloads before
  // ConnectionNotifierTools.initialize() (inside _startConnectivityWatch)
  // resolves. Polling isConnected repeatedly through that early window must
  // never throw — only a live native `connection_notifier` plugin can
  // actually reproduce the pre-fix LateInitializationError, so this is the
  // one test level below (unit/widget, which fake the plugin) that proves it.
  testWidgets('isConnected never throws when polled through early boot/init',
      (tester) async {
    app.main();
    await tester.pump();

    for (var i = 0; i < 60; i++) {
      // ignore: unnecessary_statements
      AdManager().isConnected;
      await tester.pump(const Duration(milliseconds: 100));
      if (AdManager().isInitialised) break;
    }

    expect(tester.takeException(), isNull,
        reason: 'isConnected must never throw, even before '
            'ConnectionNotifierTools.initialize() resolves');
  });
}
