// T219 on-device integration test — real app boot, navigate to the i18n
// preset demo, confirm the English preset renders, switch to Vietnamese,
// confirm the Vietnamese text actually renders on a real device (not just
// under flutter_test's synthetic environment).
//
// Run with:
//   flutter test integration_test/t219_i18n_preset_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scroll_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'switching the i18n preset toggle renders real Vietnamese text on '
      'a real device', (tester) async {
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

    final tile = find.text('i18n string presets (T219)');
    await tester.scrollUntilVisibleAndSettle(tile, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.byType(app.I18nPresetDemoPage), findsOneWidget);
    expect(
        find.text('Do Not Sell or Share My Personal Information'),
        findsOneWidget,
        reason: 'starts on the English preset');

    await tester.tap(find.text('Tiếng Việt'));
    await tester.pump();

    expect(
        find.text('Không bán hoặc chia sẻ thông tin cá nhân của tôi'),
        findsOneWidget,
        reason: 'switching the toggle must render real Vietnamese text on '
            'a real device, not just under flutter_test');
    expect(find.text('Do Not Sell or Share My Personal Information'),
        findsNothing);
    expect(tester.takeException(), isNull);
  });
}
