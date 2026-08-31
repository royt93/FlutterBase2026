// T124 — AdaptiveAdSurface widget tests. Runs WITHOUT a real ad provider
// (same convention as banner_ad_widget_test.dart) — this only tests FORMAT
// SELECTION (which child widget type is mounted), not ad rendering itself,
// so an uninitialised AdManager (both BannerAdWidget/MrecAdWidget just
// collapse to an empty box) is exactly what's needed.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(double width, {Duration debounce = Duration.zero}) {
  return MaterialApp(
    home: Center(
      child: SizedBox(
        width: width,
        height: 100,
        child: AdaptiveAdSurface(resizeDebounce: debounce),
      ),
    ),
  );
}

void main() {
  testWidgets('narrow width (< 600) renders a banner on first layout',
      (tester) async {
    await tester.pumpWidget(_wrap(320));
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(find.byType(MrecAdWidget), findsNothing);
  });

  testWidgets('wide width (>= 600) renders an MREC on first layout',
      (tester) async {
    await tester.pumpWidget(_wrap(700));
    expect(find.byType(MrecAdWidget), findsOneWidget);
    expect(find.byType(BannerAdWidget), findsNothing);
  });

  testWidgets(
      'a custom mrecBreakpoint moves the cutover', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 500,
          height: 100,
          child: AdaptiveAdSurface(mrecBreakpoint: 400),
        ),
      ),
    ));
    expect(find.byType(MrecAdWidget), findsOneWidget,
        reason: '500 >= a 400 breakpoint should already be MREC');
  });

  testWidgets(
      'a width change debounces — format does not flip until the debounce '
      'window elapses', (tester) async {
    final key = GlobalKey();
    Widget wrapWithKey(double width) => MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              height: 100,
              child: AdaptiveAdSurface(
                key: key,
                resizeDebounce: const Duration(milliseconds: 100),
              ),
            ),
          ),
        );

    await tester.pumpWidget(wrapWithKey(320));
    expect(find.byType(BannerAdWidget), findsOneWidget);

    // Widen past the breakpoint — must NOT switch immediately.
    await tester.pumpWidget(wrapWithKey(700));
    expect(find.byType(BannerAdWidget), findsOneWidget,
        reason: 'still within the debounce window — must not have switched '
            'yet');
    expect(find.byType(MrecAdWidget), findsNothing);

    // Let the debounce window elapse.
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(MrecAdWidget), findsOneWidget);
    expect(find.byType(BannerAdWidget), findsNothing);
  });

  testWidgets(
      'a width change that reverts before the debounce fires never switches '
      'at all', (tester) async {
    final key = GlobalKey();
    Widget wrapWithKey(double width) => MaterialApp(
          home: Center(
            child: SizedBox(
              width: width,
              height: 100,
              child: AdaptiveAdSurface(
                key: key,
                resizeDebounce: const Duration(milliseconds: 100),
              ),
            ),
          ),
        );

    await tester.pumpWidget(wrapWithKey(320));
    await tester.pumpWidget(wrapWithKey(700)); // debounce pending: -> mrec
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(wrapWithKey(320)); // reverted before it fired
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(BannerAdWidget), findsOneWidget,
        reason: 'the pending switch was cancelled by reverting back to the '
            'original width before its debounce fired');
    expect(find.byType(MrecAdWidget), findsNothing);
  });

  testWidgets('unmounting mid-debounce does not throw', (tester) async {
    await tester.pumpWidget(_wrap(320,
        debounce: const Duration(milliseconds: 200)));
    await tester.pumpWidget(_wrap(700,
        debounce: const Duration(milliseconds: 200)));
    // Unmount before the debounce timer fires.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 250));
    // No pending-timer-after-dispose exception reaching the test framework.
  });
}
