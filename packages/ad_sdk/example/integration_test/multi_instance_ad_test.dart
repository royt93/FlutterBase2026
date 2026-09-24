// On-device integration test for T65 — two simultaneous instances of the
// same ad widget type (Banner, MREC, Native) mounted on one real screen.
//
// Before T65 this crashed on AdMob (`AdWidget` throws `FlutterError:
// 'This AdWidget is already in the Widget tree'` when the same underlying
// ad object backs two `AdWidget`s) and silently collided on AppLovin (one
// shared adViewId/BannerListenables bundle). The demo pages
// (BannerDemoPage/MrecDemoPage/NativeDemoPage) each now render a second
// instance of their ad type specifically to exercise this on-device.
//
// Ad *content*/fill is never guaranteed (especially on a simulator), so
// this only asserts each page renders both instances and survives without
// crashing — not that a specific creative loaded.
//
// Run with:
//   flutter test integration_test/multi_instance_ad_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/widgets.dart' show IndexedStack, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// On a real device the splash flow can hit BOTH the real ATT system prompt
// AND a real UMP consent form before initialize() ever completes -- each
// has its own internal 20s timeout when nothing dismisses it headlessly (see
// AttConsent's `requestAttIfNeeded` / UmpConsent's dismiss-timeout log line),
// so worst case is ~40s of that alone before init even starts resolving.
// Budget well past that (same fix already applied in
// debug_overlay_doctor_test.dart -- 2026-08-18 fork-review: this file hit the
// tighter 30s window's real failure mode on-device).
Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

Future<void> _openDemoTile(WidgetTester tester, String tileText) async {
  final tile = find.text(tileText);
  var foundTile = false;
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (tile.evaluate().isNotEmpty) {
      foundTile = true;
      break;
    }
  }
  expect(foundTile, isTrue, reason: 'HomePage must list the "$tileText" tile');
  await tester.tap(tile);
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Banner demo renders two simultaneous banners without crashing',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    await _openDemoTile(tester, 'Banner ad');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.text('Banner demo'), findsOneWidget);
    // BannerDemoPage also embeds a third, unrelated BannerAdWidget further
    // down the page (the "IndexedStack via buildBanner() (T153)" example)
    // purely to demonstrate the IndexedStack/`active` pattern — exclude
    // anything inside that IndexedStack so this assertion stays about the
    // actual T65 multi-instance feature, not that demo (2026-09-23: found
    // failing 3 vs 2 on a real device; this widget was always there, not a
    // leaked previous-route instance as first assumed — same root cause as
    // the Native test's T154 case just below, but T153 has no distinguishing
    // key to filter on directly).
    final t153Banners = find
        .descendant(
          of: find.byType(IndexedStack, skipOffstage: false),
          matching: find.byType(BannerAdWidget, skipOffstage: false),
          skipOffstage: false,
        )
        .evaluate()
        .length;
    final t65BannerWidgets =
        find.byType(BannerAdWidget, skipOffstage: false).evaluate().length -
            t153Banners;
    expect(t65BannerWidgets, 2,
        reason: 'demo page must mount two independent BannerAdWidget '
            'instances (T65) — skipOffstage:false because an unfilled/VIP-'
            'suppressed instance collapses to a zero-height SizedBox.shrink(), '
            'and two stacked zero-height widgets confuse the default filter '
            '(2026-08-18 fork-review)');
    expect(tester.takeException(), isNull);
  });

  testWidgets('MREC demo renders two simultaneous MRECs without crashing',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    await _openDemoTile(tester, 'MREC ad');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.text('MREC demo'), findsOneWidget);
    expect(find.byType(MrecAdWidget, skipOffstage: false), findsNWidgets(2),
        reason: 'demo page must mount two independent MrecAdWidget instances '
            '(T65) — skipOffstage:false, see the Banner test above');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Native demo renders two simultaneous natives without crashing',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    await _openDemoTile(tester, 'Native ad');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(find.text('Native demo'), findsOneWidget);
    // NativeDemoPage also embeds a third, unrelated NativeAdWidget further
    // down the page (key 'T154_indexedstack_demo') purely to demonstrate the
    // IndexedStack/`active` pattern — exclude it by key so this assertion
    // stays about the actual T65 multi-instance feature, not that demo
    // (2026-09-23: found failing 3 vs 2 on a real device; this widget was
    // always there, not a leaked previous-route instance as first assumed).
    final t65NativeWidgets = find
        .byType(NativeAdWidget, skipOffstage: false)
        .evaluate()
        .where((e) => e.widget.key != const ValueKey('T154_indexedstack_demo'))
        .length;
    expect(t65NativeWidgets, 2,
        reason: 'demo page must mount two independent NativeAdWidget instances '
            '(T65) — skipOffstage:false, see the Banner test above');
    expect(tester.takeException(), isNull);
  });
}
