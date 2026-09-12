// Widget test for CustomOverlayDemoPage (T168) — the demo screen that
// shows a popup built via a raw Overlay.insert(), the case
// AdScreenRouteLogger.isDialogOnTop cannot see on its own.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => markCustomOverlayOnScreen(false));

  Widget host() => const MaterialApp(home: CustomOverlayDemoPage());

  testWidgets(
      'showing the custom overlay sets customOverlayOnScreen, closing it '
      'clears it back', (tester) async {
    await tester.pumpWidget(host());
    expect(customOverlayOnScreen.value, isFalse);
    expect(find.text('Show custom overlay'), findsOneWidget);
    expect(find.textContaining('Background the app and bring it back'),
        findsNothing,
        reason: 'the overlay content itself is not shown yet');

    await tester.tap(find.text('Show custom overlay'));
    await tester.pump();

    expect(customOverlayOnScreen.value, isTrue,
        reason: 'T168 — the demo must call markCustomOverlayOnScreen(true) '
            'right when it inserts its own overlay');
    expect(find.text('Close overlay'), findsOneWidget);
    expect(find.text('customOverlayOnScreen: true'), findsOneWidget);

    await tester.tap(find.text('Close overlay'));
    await tester.pump();

    expect(customOverlayOnScreen.value, isFalse,
        reason: 'T168 — closing the overlay must clear the flag back');
    expect(find.text('Close overlay'), findsNothing);
    expect(find.text('customOverlayOnScreen: false'), findsOneWidget);
  });

  testWidgets(
      'while the custom overlay is shown, canShowInterstitial() is false '
      'on the real AdManager — proving the flag actually reaches the '
      'fullscreen mutex, not just this page\'s own local state',
      (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.text('Show custom overlay'));
    await tester.pump();

    expect(AdManager().canShowInterstitial(), isFalse,
        reason: 'T168 — a real fullscreen ad path must be blocked while '
            'this demo\'s custom overlay is shown');

    await tester.tap(find.text('Close overlay'));
    await tester.pump();

    expect(customOverlayOnScreen.value, isFalse);
  });

  testWidgets('disposing the page while the overlay is still open clears '
      'the flag (demo hygiene, not a leaked block for the rest of the '
      'session)', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('Show custom overlay'));
    await tester.pump();
    expect(customOverlayOnScreen.value, isTrue);

    // Navigate away WITHOUT closing the overlay first.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(customOverlayOnScreen.value, isFalse,
        reason: 'T168 — the demo\'s own dispose() must not leave every '
            'fullscreen ad blocked for the rest of the session just '
            'because the host navigated away without closing its popup');
  });
}
