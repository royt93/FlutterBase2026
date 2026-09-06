// Widget test for RemoteSafetyDemoPage's R3-01 failure-branch fix — a real
// AdManager().initialize() failure is network-dependent and not reliably
// forceable from a test, so this uses the page's test-only
// debugForceApplyResult/debugForceRestoreResult seam to deterministically
// exercise `onComplete(false, ...)` without touching the real SDK. The
// happy path (a real init actually succeeding) is proven on-device instead:
// example/integration_test/round40_remote_safety_demo_test.dart and
// round40_remote_safety_demo_restore_test.dart.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    RemoteSafetyDemoPage.debugForceApplyResult = null;
    RemoteSafetyDemoPage.debugForceRestoreResult = null;
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: RemoteSafetyDemoPage()));
  }

  testWidgets(
      'R3-01: a false onComplete from Apply shows a failure status and '
      'does not flip the page into the wired state', (tester) async {
    RemoteSafetyDemoPage.debugForceApplyResult = false;
    await pumpPage(tester);

    await tester
        .tap(find.text('Apply provider (destroy + re-initialize)'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
        find.textContaining(
            'Failed to apply provider — the SDK did not initialize.'),
        findsOneWidget);
    expect(find.text('Provider already wired'), findsNothing,
        reason: 'a false success must not be treated as wired');
    expect(find.text('Apply provider (destroy + re-initialize)'),
        findsOneWidget,
        reason: 'the button must stay in its unwired, re-tappable state');
  });

  testWidgets(
      'R3-01: a false onComplete from Restore shows a failure status and '
      'leaves the wired state untouched', (tester) async {
    RemoteSafetyDemoPage.debugForceApplyResult = true;
    await pumpPage(tester);
    await tester
        .tap(find.text('Apply provider (destroy + re-initialize)'));
    await tester.pumpAndSettle();
    expect(find.text('Provider already wired'), findsOneWidget,
        reason: 'sanity: must be wired before exercising restore-failure');

    RemoteSafetyDemoPage.debugForceRestoreResult = false;
    await tester.tap(
        find.text('Restore demo defaults (destroy + re-initialize)'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
        find.textContaining(
            'Failed to restore defaults — the SDK did not initialize.'),
        findsOneWidget);
    expect(find.text('Provider already wired'), findsOneWidget,
        reason: 'a failed restore must not silently detach the provider '
            'in the UI\'s eyes');
  });
}
