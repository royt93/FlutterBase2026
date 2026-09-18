// Widget test for RemoteSafetyDemoPage's R3-01 failure-branch fix — a real
// AdManager().initialize() failure is network-dependent and not reliably
// forceable from a test, so this uses the page's test-only
// debugForceApplyResult/debugForceRestoreResult seam to deterministically
// exercise `onComplete(false, ...)` without touching the real SDK. The
// happy path (a real init actually succeeding) is proven on-device instead:
// example/integration_test/round40_remote_safety_demo_test.dart and
// round40_remote_safety_demo_restore_test.dart.

import 'dart:async';

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    RemoteSafetyDemoPage.debugForceApplyResult = null;
    RemoteSafetyDemoPage.debugForceRestoreResult = null;
    RemoteSafetyDemoPage.debugApplyGate = null;
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

  // Audit round 42, MINOR — this page had no dispose() at all despite
  // owning a ValueNotifier AND having globally rewired the live AdManager's
  // safety config via initialize(remoteSafetyProvider: _provider, ...).
  // Leaving without tapping "Restore demo defaults" used to leave that
  // rewiring in place for the rest of the session.
  testWidgets(
      'round 42: leaving the page while still wired triggers the same '
      'restore-defaults cleanup as tapping the button would',
      (tester) async {
    RemoteSafetyDemoPage.debugRestoreCallCount = 0;
    RemoteSafetyDemoPage.debugForceApplyResult = true;
    RemoteSafetyDemoPage.debugForceRestoreResult = true;
    await pumpPage(tester);
    await tester
        .tap(find.text('Apply provider (destroy + re-initialize)'));
    await tester.pumpAndSettle();
    expect(find.text('Provider already wired'), findsOneWidget,
        reason: 'sanity: must be wired before exercising the dispose path');

    // Leave the page WITHOUT tapping "Restore demo defaults".
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(RemoteSafetyDemoPage.debugRestoreCallCount, 1,
        reason: 'dispose() must run the same restore-defaults cleanup a '
            'tap on the button would, when the provider is still wired');
  });

  testWidgets(
      'round 42: leaving the page while NOT wired triggers no cleanup',
      (tester) async {
    RemoteSafetyDemoPage.debugRestoreCallCount = 0;
    await pumpPage(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(RemoteSafetyDemoPage.debugRestoreCallCount, 0,
        reason: 'nothing to clean up when the provider was never applied');
  });

  // Re-audit follow-up (post round-42) — dispose() only cleans up when
  // `_wired` is already true, but `_wired` only flips true AFTER
  // `_applyProvider()`'s own await resolves. If the page is navigated away
  // from WHILE an Apply is still in flight, dispose() runs first, sees
  // `_wired == false`, and skips cleanup — yet the in-flight call can still
  // go on to successfully attach `_provider` to the live AdManager
  // singleton, leaving it wired with nobody left to restore it.
  testWidgets(
      're-audit: navigating away WHILE Apply is still in flight still '
      'restores defaults once that in-flight call resolves',
      (tester) async {
    RemoteSafetyDemoPage.debugRestoreCallCount = 0;
    RemoteSafetyDemoPage.debugForceApplyResult = true;
    RemoteSafetyDemoPage.debugForceRestoreResult = true;
    final gate = Completer<void>();
    RemoteSafetyDemoPage.debugApplyGate = gate;
    await pumpPage(tester);

    // Tap, then pump — this starts `_applyProvider()`, which immediately
    // parks on `gate.future`, exactly where the real destroy()/initialize()
    // await sits. The apply is now genuinely, deterministically in flight.
    await tester
        .tap(find.text('Apply provider (destroy + re-initialize)'));
    await tester.pump();

    // Navigate away WHILE the apply is still parked on the gate — the
    // exact interleaving that used to leave the SDK wired with no cleanup.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    // Only now let the in-flight apply resolve, after the page is gone.
    gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(RemoteSafetyDemoPage.debugRestoreCallCount, 1,
        reason: 'the in-flight apply call must notice it is unmounted once '
            'it resolves and restore defaults itself, since dispose() ran '
            'too early to know the apply would succeed');
  });
}
