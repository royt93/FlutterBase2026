// Coverage was 0% — no test file existed for vip_dialog.dart at all.
// Covers: verifying dialog (non-dismissable, shows/dismisses via caller pop),
// success dialog (formatted date + confirm button pops), failed dialog
// (custom message + confirm button pops).

import 'package:applovin_admob_sdk/src/vip/vip_dialog.dart';
import 'package:applovin_admob_sdk/src/vip/vip_dialog_strings.dart';
import 'package:applovin_admob_sdk/src/vip/vip_entry.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

const _strings = VipDialogStrings();

Future<BuildContext> pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(CupertinoApp(
    home: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }),
  ));
  return ctx;
}

void main() {
  testWidgets(
      'showVipVerifyingDialog shows activity indicator, not '
      'barrier-dismissable, caller pop closes it', (tester) async {
    final ctx = await pumpHost(tester);

    showVipVerifyingDialog(ctx, _strings);
    await tester.pump();
    await tester.pump();

    expect(find.text(_strings.verifyingTitle), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

    // Tapping the barrier must NOT dismiss (barrierDismissible: false).
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text(_strings.verifyingTitle), findsOneWidget);

    Navigator.of(ctx, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    expect(find.text(_strings.verifyingTitle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'showVipSuccessDialog renders formatted expiry date, confirm pops',
      (tester) async {
    final ctx = await pumpHost(tester);
    final entry = VipEntry(
      key: 'K',
      expiresAt: DateTime(2026, 8, 15, 9, 5),
      grantedAt: DateTime(2026, 7, 11),
    );

    showVipSuccessDialog(ctx, _strings, entry);
    await tester.pumpAndSettle();

    expect(find.text(_strings.successTitle), findsOneWidget);
    expect(
        find.text(_strings.successMessage('2026-08-15 09:05')), findsOneWidget);

    await tester.tap(find.text(_strings.confirmButton));
    await tester.pumpAndSettle();

    expect(find.text(_strings.successTitle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showVipFailedDialog renders the given message, confirm pops',
      (tester) async {
    final ctx = await pumpHost(tester);

    showVipFailedDialog(ctx, _strings, 'Custom failure reason');
    await tester.pumpAndSettle();

    expect(find.text(_strings.failedTitle), findsOneWidget);
    expect(find.text('Custom failure reason'), findsOneWidget);

    await tester.tap(find.text(_strings.confirmButton));
    await tester.pumpAndSettle();

    expect(find.text(_strings.failedTitle), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
