// Widget test for BannerDemoPage's T153 IndexedStack demo (buildBanner()
// forwarding `active`). Needs a real, initialised adapter to prove the
// underlying claim (see test/ad_screen_test.dart in the SDK package itself
// for that proof, plus banner_ad_widget_test.dart's own active:false/true
// coverage) — this only pins that switching tabs before SDK init doesn't
// crash the page.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'T153 — switching IndexedStack tabs before SDK init does not crash',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BannerDemoPage()));
    await tester.pump();

    expect(find.text('Tab 1 — nothing here'), findsOneWidget);

    await tester.tap(find.text('Tab 2 (banner)'));
    await tester.pump();

    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Tab 1 (no ad)'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Tab 1 — nothing here'), findsOneWidget);
  });
}
