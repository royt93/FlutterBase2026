// T13 — AdLoadingDialog.resetState must pop a still-showing dialog so a
// mid-dialog destroy/re-init can't strand a non-dismissable loading dialog on
// the navigator (which would block a fresh dialog and freeze the UI).

import 'package:applovin_admob_sdk/src/widget/ad_loading_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('resetState pops a showing dialog and clears isShowing',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ),
    ));

    AdLoadingDialog.show(ctx);
    await tester.pump(); // let the dialog route push
    expect(AdLoadingDialog.isShowing, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Simulate AdManager.destroy() mid-dialog.
    AdLoadingDialog.resetState();
    await tester.pump(const Duration(milliseconds: 50));

    expect(AdLoadingDialog.isShowing, isFalse);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'dialog was popped, not stranded');
    expect(tester.takeException(), isNull);
  });

  testWidgets('resetState is a safe no-op when nothing is showing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    AdLoadingDialog.resetState();
    expect(AdLoadingDialog.isShowing, isFalse);
    expect(tester.takeException(), isNull);
  });

  // Regression: resetState() popping mid-showAdBuffer used to leave the
  // buffer's own Future.delayed pending — when it later fired it would pop
  // whatever route happened to be on top instead of noticing its dialog was
  // already gone. The _generation guard makes the stale timer a no-op.
  group('showAdBuffer generation guard (stranded-dialog fix)', () {
    Future<void> pumpHost(
      WidgetTester tester,
      void Function(BuildContext) onPressed,
    ) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => onPressed(context),
            child: const Text('go'),
          ),
        ),
      ));
    }

    setUp(() {
      AdLoadingDialog.resetState();
    });

    testWidgets(
        'resetState mid-buffer pops once; the stale timer skips its own pop',
        (tester) async {
      var onCompleteCalls = 0;
      await pumpHost(tester, (context) {
        AdLoadingDialog.showAdBuffer(
          context,
          durationMs: 500,
          onComplete: () => onCompleteCalls++,
        );
      });

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(AdLoadingDialog.isShowing, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Something else (e.g. AdManager.destroy()) pops mid-buffer.
      AdLoadingDialog.resetState();
      await tester.pumpAndSettle();

      expect(AdLoadingDialog.isShowing, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Let the original buffer timer actually elapse — must not throw
      // trying to pop an already-gone route, and must still fire onComplete
      // exactly once (from the stale-generation branch), not twice.
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull);
      expect(onCompleteCalls, 1);
      expect(AdLoadingDialog.isShowing, isFalse);
    });

    testWidgets('normal path: timer elapses, dialog pops, onComplete fires',
        (tester) async {
      var onCompleteCalls = 0;
      await pumpHost(tester, (context) {
        AdLoadingDialog.showAdBuffer(
          context,
          durationMs: 200,
          onComplete: () => onCompleteCalls++,
        );
      });

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(AdLoadingDialog.isShowing, isTrue);

      await tester.pump(const Duration(milliseconds: 250));

      expect(onCompleteCalls, 1);
      expect(AdLoadingDialog.isShowing, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Proxy for "_activeNavigator was cleared cleanly": a fresh buffer
      // must be able to show and dismiss right after, with no leftover
      // state.
      await pumpHost(tester, (context) {
        AdLoadingDialog.showAdBuffer(
          context,
          durationMs: 50,
          onComplete: () => onCompleteCalls++,
        );
      });
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(AdLoadingDialog.isShowing, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(onCompleteCalls, 2);
      expect(AdLoadingDialog.isShowing, isFalse);
    });

    testWidgets('double-tap while showing skips the duplicate immediately',
        (tester) async {
      var completions = 0;
      await pumpHost(tester, (context) {
        AdLoadingDialog.showAdBuffer(
          context,
          durationMs: 300,
          onComplete: () => completions++,
        );
      });

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(AdLoadingDialog.isShowing, isTrue);

      // Second call while still showing: must call its own onComplete right
      // away without touching the first dialog.
      var secondComplete = false;
      AdLoadingDialog.showAdBuffer(
        tester.element(find.byType(ElevatedButton)),
        durationMs: 300,
        onComplete: () => secondComplete = true,
      );
      expect(secondComplete, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'still only the first dialog on screen');

      await tester.pump(const Duration(milliseconds: 350));
      expect(completions, 1);
      expect(AdLoadingDialog.isShowing, isFalse);
    });
  });
}
