// On-device: rotating while a banner is mounted must not crash, must keep the
// page alive, and the banner must be loadable again once back in portrait.
//
// Rotation is real (SystemChrome -> Android requests an orientation change);
// the test asserts the window really changed shape so it cannot pass without
// rotating. Ad fill right after a rotation is Google's to give, so only the
// final portrait state asserts a loaded banner, inside a bounded window.
//
// Run (clear app data first, see README.md):
//   flutter test integration_test/orientation_rotation_banner_test.dart \
//     -d <device-id> --dart-define=AD_PROVIDER_ADMOB=true

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _pumpFor(WidgetTester tester, int ms) async {
  for (var i = 0; i < ms ~/ 250; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _rotate(
  WidgetTester tester,
  List<DeviceOrientation> orientations,
  bool landscape,
) async {
  await SystemChrome.setPreferredOrientations(orientations);
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    final s = tester.view.physicalSize;
    if ((s.width > s.height) == landscape) break;
  }
  final s = tester.view.physicalSize;
  expect(
    s.width > s.height,
    landscape,
    reason: 'window did not rotate to ${landscape ? 'landscape' : 'portrait'}',
  );
  await _pumpFor(tester, 1500);
}

int _readyBanners(WidgetTester tester) {
  final adapter = AdManager().adapter!;
  return tester
      .stateList(find.byType(BannerAdWidget))
      .where((k) => adapter.bannerSlot(k).isReady)
      .length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('banner survives portrait -> landscape -> portrait', (
    tester,
  ) async {
    addTearDown(() => SystemChrome.setPreferredOrientations([]));
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    app.main();
    await tester.pump();
    for (var i = 0; i < 180 && !AdManager().isInitialised; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(AdManager().isInitialised, isTrue);
    await AdManager().vip?.revokeAll();
    await tester.pump();

    final tile = find.text('Banner ad');
    for (var i = 0; i < 40 && tile.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(tile, findsOneWidget, reason: 'HomePage must list the Banner tile');
    await tester.tap(tile);
    await _pumpFor(tester, 10000);
    expect(find.text('Banner demo'), findsOneWidget);
    expect(_readyBanners(tester), greaterThan(0),
        reason: 'banner must load in portrait before rotating');

    for (var cycle = 0; cycle < 2; cycle++) {
      await _rotate(tester, [DeviceOrientation.landscapeLeft], true);
      expect(find.text('Banner demo'), findsOneWidget);
      expect(find.byType(BannerAdWidget), findsWidgets);
      expect(tester.takeException(), isNull, reason: 'landscape cycle $cycle');

      await _rotate(tester, [DeviceOrientation.portraitUp], false);
      expect(find.text('Banner demo'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'portrait cycle $cycle');
    }

    var ready = 0;
    for (var i = 0; i < 40 && ready == 0; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      ready = _readyBanners(tester);
    }
    expect(ready, greaterThan(0),
        reason: 'banner must be loadable again after two rotation cycles');
    expect(tester.takeException(), isNull);
  });
}
