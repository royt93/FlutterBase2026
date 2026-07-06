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
}
