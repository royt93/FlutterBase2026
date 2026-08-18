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
    expect(find.byType(BannerAdWidget), findsNWidgets(2),
        reason: 'demo page must mount two independent BannerAdWidget '
            'instances (T65)');
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
    expect(find.byType(MrecAdWidget), findsNWidgets(2),
        reason: 'demo page must mount two independent MrecAdWidget instances '
            '(T65)');
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
    expect(find.byType(NativeAdWidget), findsNWidgets(2),
        reason: 'demo page must mount two independent NativeAdWidget instances '
            '(T65)');
    expect(tester.takeException(), isNull);
  });
}
