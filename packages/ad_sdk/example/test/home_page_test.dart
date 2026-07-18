// Widget test for HomePage: the demo list renders every DemoTile and tapping
// one navigates to the right destination page — all pre-SDK-init, since
// HomePage and its destinations are safe to build without a real adapter.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpHomePage(WidgetTester tester) async {
    // The list has 15 tiles — grow the viewport so they all build without
    // needing a scroll gesture.
    tester.view.physicalSize = const Size(800, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
  }

  testWidgets('renders a DemoTile for every demo', (tester) async {
    await pumpHomePage(tester);

    expect(find.byType(DemoTile), findsNWidgets(15));
    expect(find.text('Banner ad'), findsOneWidget);
    expect(find.text('MREC ad'), findsOneWidget);
    expect(find.text('Native ad'), findsOneWidget);
    expect(find.text('Compliance report'), findsOneWidget);
  });

  testWidgets('tapping a tile navigates to its destination page',
      (tester) async {
    await pumpHomePage(tester);

    await tester.tap(find.text('Safety status'));
    await tester.pumpAndSettle();

    expect(find.byType(SafetyDemoPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
  });
}
