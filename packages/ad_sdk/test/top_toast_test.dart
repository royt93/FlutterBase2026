import 'package:applovin_admob_sdk/src/widget/top_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the "single active toast" invariant: [TopToast.show] always
/// dismisses any prior toast first, plus the auto-dismiss timer and
/// tap-to-dismiss-early path.
void main() {
  Widget harness(BuildContext Function(BuildContext) capture) {
    return MaterialApp(
      home: Builder(builder: (context) {
        capture(context);
        return const Scaffold(body: SizedBox.shrink());
      }),
    );
  }

  testWidgets('show() twice leaves only the latest toast on screen',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(harness((c) => ctx = c));

    TopToast.show(ctx, icon: Icons.info, message: 'first');
    await tester.pump();
    expect(find.text('first'), findsOneWidget);

    TopToast.show(ctx, icon: Icons.info, message: 'second');
    await tester.pump();
    expect(find.text('first'), findsNothing,
        reason:
            'show() must dismiss the prior toast before inserting a new one');
    expect(find.text('second'), findsOneWidget);

    // Let both toasts' internal timers/animations run out without throwing —
    // the first toast's orphaned Future.delayed(_animateOut) must no-op
    // safely since its State is already unmounted.
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('toast auto-dismisses after duration elapses', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(harness((c) => ctx = c));

    TopToast.show(
      ctx,
      icon: Icons.check,
      message: 'auto-dismiss-me',
      duration: const Duration(milliseconds: 200),
    );
    // Existence in the tree doesn't depend on the fade/slide animation
    // having finished — check right after the first frame.
    await tester.pump();
    expect(find.text('auto-dismiss-me'), findsOneWidget);

    // The 200ms auto-dismiss delay and the forward animation both start at
    // show()-time, so the delay can fire mid-forward-animation — reverse
    // then only needs to cover however much of the forward animation had
    // played. 700ms comfortably covers delay + a full reverse either way.
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('auto-dismiss-me'), findsNothing);
  });

  testWidgets('tapping the toast dismisses it before the timer fires',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(harness((c) => ctx = c));

    TopToast.show(
      ctx,
      icon: Icons.check,
      message: 'tap-dismiss-me',
      duration: const Duration(seconds: 5),
    );
    await tester.pumpAndSettle();
    expect(find.text('tap-dismiss-me'), findsOneWidget);

    await tester.tap(find.text('tap-dismiss-me'));
    await tester.pumpAndSettle();
    expect(find.text('tap-dismiss-me'), findsNothing,
        reason: 'manual tap must dismiss before the auto-dismiss timer fires');

    // The original 5s timer firing later on an unmounted State must not throw.
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });
}
