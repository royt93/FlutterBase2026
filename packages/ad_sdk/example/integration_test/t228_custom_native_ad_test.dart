// On-device integration test for T228's custom native ad layout demo card
// on NativeDemoPage.
//
// AdMob path: NativeAdWidget(factoryId: 't228CustomNativeAd') must load
// without crashing against the REAL T228CustomNativeAdFactory registered in
// MainActivity.kt (Android) / AppDelegate.swift (iOS) — this is the actual
// native-platform-code proof this ticket required; a widget test alone
// cannot exercise the platform-side factory registration at all.
//
// AppLovin path: NativeAdWidget(customNativeAdBuilder: ...) is pure Dart —
// covered thoroughly by widget tests already; this just confirms it also
// mounts for real on-device alongside the rest of the demo page.
//
// Run with:
//   flutter test integration_test/t228_custom_native_ad_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// See native_ad_test.dart's twin of this helper for why the budget is this
// generous (real ATT + real UMP consent forms can each eat ~20s on-device).
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
      'T228 custom native layout demo card renders without crashing',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Debug builds grant a short first-install VIP grace; every ad surface
    // correctly refuses to load while it's active. This test's purpose is
    // proving the REAL native factory runs, so wait out that gate first
    // (max 35s in this example; production/release grace is not used here).
    for (var i = 0;
        i < 70 && (AdManager().vip?.isActive ?? false);
        i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(AdManager().vip?.isActive ?? false, isFalse,
        reason: 'first-install VIP grace must expire before testing a real '
            'native ad load');

    final tile = find.text('Native ad');
    var foundTile = false;
    // 120 iterations (60s), matching banner_indexedstack_visibility_test.dart's
    // convention — a real splash App Open ad (bypassSafety=true) can cover
    // HomePage and take a while to auto-dismiss; 20s was too tight and made
    // this flaky on a real fill, not a code bug.
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Native ad tile (a real splash App '
            'Open ad may be covering it and take a while to auto-dismiss)');
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 500));

    // Scroll the demo page down to the T228 card, same bounded-window
    // convention as other real-network ad-load waits in this suite. Finders
    // only see built ListView children, so keep scrolling until the label is
    // actually mounted (not a fixed number of drags guessed from one device).
    final listFinder = find.byType(Scrollable).first;
    final t228Label = find.text('T228 — custom native layout');
    for (var i = 0; i < 20 && t228Label.evaluate().isEmpty; i++) {
      await tester.drag(listFinder, const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Real ad inventory is asynchronous; give the native factory up to 20s
    // to receive a fill and inflate its platform view.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(t228Label, findsOneWidget,
        reason: 'the T228 demo card must render regardless of provider');
    expect(
      find.byKey(AdManager().isAdMobProvider
          ? const ValueKey('T228_admob_custom_factory_demo')
          : const ValueKey('T228_applovin_custom_demo')),
      findsOneWidget,
      reason: 'the provider-specific NativeAdWidget instance must mount',
    );
    expect(tester.takeException(), isNull,
        reason: 'no crash — real factoryId + real native platform code, or '
            'real customNativeAdBuilder, must not throw');
  });
}
