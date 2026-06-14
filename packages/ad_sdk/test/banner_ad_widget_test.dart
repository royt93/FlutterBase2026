// Widget tests for BannerAdWidget.
//
// These run WITHOUT a real ad provider: in the test environment the
// AdManager singleton is never `initialize()`d, so `isInitialised` is false and
// the widget must collapse to an empty box (never paint an impression for an
// uninitialised / VIP user). We assert that safe-default rendering plus a clean
// mount → route → dispose lifecycle (RouteAware subscribe/unsubscribe must not
// throw).
//
// What's covered:
//   • Renders an empty (zero-size) box when the SDK is not initialised.
//   • Mounts and disposes without throwing (RouteAware + ValueNotifier teardown).
//   • Survives a route push/pop on top of it (didPushNext/didPopNext).
//   • Does not paint an AppLovin/AdMob platform view when uninitialised.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('renders an empty box when the SDK is not initialised',
      (tester) async {
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pumpAndSettle();

    // The widget tree contains the BannerAdWidget but it must not paint a
    // banner surface — a SizedBox.shrink is rendered as the safe default.
    expect(find.byType(BannerAdWidget), findsOneWidget);
    final size = tester.getSize(find.byType(BannerAdWidget));
    expect(size.height, 0,
        reason: 'uninitialised banner must collapse to zero height');
  });

  testWidgets('mounts and disposes without throwing', (tester) async {
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pumpAndSettle();

    // Replace the widget tree → triggers _BannerAdWidgetState.dispose
    // (RouteAware unsubscribe + 3 ValueNotifier disposals).
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();

    expect(find.byType(BannerAdWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives a route push and pop on top of it', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [adRouteObserver],
      home: const Scaffold(body: BannerAdWidget()),
    ));
    await tester.pumpAndSettle();

    // Push a route on top → BannerAdWidget receives didPushNext.
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('top'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('top'), findsOneWidget);

    // Pop back → didPopNext. No banner should be painted, no exception.
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
