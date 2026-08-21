// Widget test for the AdMob test-device hash demo page (§19).
//
// Exercises the GAID/zero-GUID display state and both copy buttons.
// Mocks the platform clipboard channel — flutter_test's default handler
// never replies to Clipboard.setData/getData, so awaiting it hangs.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? clipboardText;

  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    AdManager().debugCurrentDeviceGAID = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TestDeviceHashDemoPage()));
  }

  testWidgets('empty GAID shows the placeholder and disables the copy button',
      (tester) async {
    AdManager().debugCurrentDeviceGAID = '';
    await pumpPage(tester);

    expect(find.text('(empty — init not done yet, or LAT on)'), findsOneWidget);
    await tester.tap(find.text('Copy GAID (not the AdMob hash!)'));
    await tester.pump();
    expect(clipboardText, isNull);
  });

  testWidgets('all-zero GUID is treated the same as empty', (tester) async {
    AdManager().debugCurrentDeviceGAID = '00000000-0000-0000-0000-000000000000';
    await pumpPage(tester);

    expect(find.text('(empty — init not done yet, or LAT on)'), findsOneWidget);
  });

  testWidgets('copying the GAID puts it on the clipboard and shows a toast',
      (tester) async {
    AdManager().debugCurrentDeviceGAID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    await pumpPage(tester);

    await tester.tap(find.text('Copy GAID (not the AdMob hash!)'));
    await tester.pump();

    expect(clipboardText, 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE');
    expect(find.text('GAID copied to clipboard'), findsOneWidget);
  });

  testWidgets('copying the hint puts it on the clipboard and shows a toast',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Copy hint text'));
    await tester.pump();

    expect(clipboardText, contains('logcat'));
    expect(find.text('Hint copied to clipboard'), findsOneWidget);
  });

  // Issue 3 — _resetGuardState() (run by destroy()) must clear the stale
  // GAID it left over from the previous session. This page reads
  // AdManager().currentDeviceGaid directly in build(), so it's the most
  // direct proof the clear is actually observable by something a user could
  // be looking at, not just an internal field.
  testWidgets(
      'GAID displayed collapses to the placeholder once the guard state is '
      'reset', (tester) async {
    AdManager().debugCurrentDeviceGAID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    await pumpPage(tester);
    expect(find.text('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'), findsOneWidget);

    AdManager().debugResetGuardState();
    // StatelessWidget — nothing subscribes to a listenable for this value,
    // and MaterialApp.home only seeds the Navigator's initial route ONCE:
    // pumping the same MaterialApp(home: ...) again does not rebuild the
    // page. Unmount everything first (a different root widget type) so the
    // next pumpPage() creates a genuinely fresh page, reading the value
    // anew — the same as a real navigation back to this page after a
    // destroy()/re-init would.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPage(tester);

    expect(find.text('(empty — init not done yet, or LAT on)'),
        findsOneWidget,
        reason: 'a stale GAID surviving past destroy() would keep showing '
            'here as if the SDK still had it');
  });
}
