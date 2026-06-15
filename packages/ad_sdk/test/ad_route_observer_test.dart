import 'dart:async';

import 'package:applovin_admob_sdk/src/core/ad_route_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the dialog/popup tracking that App Open ads rely on to avoid showing
/// a fullscreen ad on top of a modal (consent dialog, VIP redeem, etc).
void main() {
  setUp(AdScreenRouteLogger.resetState);
  tearDown(AdScreenRouteLogger.resetState);

  testWidgets('isDialogOnTop flips while a dialog is presented', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [AdScreenRouteLogger()],
      home: const Scaffold(body: Text('home')),
    ));

    expect(AdScreenRouteLogger.isDialogOnTop, isFalse,
        reason: 'plain home page is not a popup');

    // Pushing a normal page must NOT count as a dialog.
    unawaited(navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('page')),
    ));
    await tester.pumpAndSettle();
    expect(AdScreenRouteLogger.isDialogOnTop, isFalse,
        reason: 'MaterialPageRoute is not a PopupRoute');

    // A dialog (PopupRoute) must flip the flag on.
    unawaited(showDialog<void>(
      context: navKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    ));
    await tester.pumpAndSettle();
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue);

    // Dismissing it flips the flag back off.
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(AdScreenRouteLogger.isDialogOnTop, isFalse);
  });

  testWidgets('nested dialogs require both to close before clearing',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [AdScreenRouteLogger()],
      home: const Scaffold(body: Text('home')),
    ));

    unawaited(showDialog<void>(
      context: navKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('first')),
    ));
    await tester.pumpAndSettle();
    unawaited(showDialog<void>(
      context: navKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('second')),
    ));
    await tester.pumpAndSettle();
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue);

    navKey.currentState!.pop(); // close second
    await tester.pumpAndSettle();
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue,
        reason: 'one dialog still open');

    navKey.currentState!.pop(); // close first
    await tester.pumpAndSettle();
    expect(AdScreenRouteLogger.isDialogOnTop, isFalse);
  });

  test('resetState clears a stuck counter and never goes negative', () {
    final logger = AdScreenRouteLogger();
    final popup = _FakePopupRoute();

    logger.didPush(popup, null);
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue);

    AdScreenRouteLogger.resetState();
    expect(AdScreenRouteLogger.isDialogOnTop, isFalse);

    // Stray pop on an empty stack must not drive the counter negative.
    logger.didPop(popup, null);
    expect(AdScreenRouteLogger.isDialogOnTop, isFalse);
    logger.didPush(popup, null);
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue);
  });
}

/// Minimal [PopupRoute] for the pure-Dart counter test.
class _FakePopupRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      const SizedBox.shrink();

  @override
  Duration get transitionDuration => Duration.zero;
}
