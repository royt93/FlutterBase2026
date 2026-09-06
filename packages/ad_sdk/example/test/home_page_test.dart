// Widget test for HomePage: the demo list renders every DemoTile and tapping
// one navigates to the right destination page — all pre-SDK-init, since
// HomePage and its destinations are safe to build without a real adapter.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpHomePage(WidgetTester tester) async {
    // The list has 21 tiles — grow the viewport so they all build without
    // needing a scroll gesture.
    tester.view.physicalSize = const Size(800, 4600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
  }

  testWidgets('renders a DemoTile for every demo', (tester) async {
    await pumpHomePage(tester);

    expect(find.byType(DemoTile), findsNWidgets(21));
    expect(find.text('Banner ad'), findsOneWidget);
    expect(find.text('MREC ad'), findsOneWidget);
    expect(find.text('Native ad'), findsOneWidget);
    expect(find.text('Rewarded interstitial ad'), findsOneWidget);
    expect(find.text('Compliance report'), findsOneWidget);
    expect(find.text('Remote safety provider (T88)'), findsOneWidget);
    expect(find.text('Splash shortcut (T94)'), findsOneWidget);
  });

  testWidgets('tapping a tile navigates to its destination page',
      (tester) async {
    await pumpHomePage(tester);

    await tester.tap(find.text('Safety status'));
    await tester.pumpAndSettle();

    expect(find.byType(SafetyDemoPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
  });

  testWidgets(
      'tapping the remote safety provider tile navigates to '
      'RemoteSafetyDemoPage', (tester) async {
    await pumpHomePage(tester);

    await tester.tap(find.text('Remote safety provider (T88)'));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteSafetyDemoPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
  });

  testWidgets(
      'tapping the splash shortcut tile navigates to '
      'ReadinessControllerDemoPage', (tester) async {
    await pumpHomePage(tester);

    await tester.tap(find.text('Splash shortcut (T94)'));
    await tester.pumpAndSettle();

    expect(find.byType(ReadinessControllerDemoPage), findsOneWidget);
    expect(find.byType(HomePage), findsNothing);
  });
}
