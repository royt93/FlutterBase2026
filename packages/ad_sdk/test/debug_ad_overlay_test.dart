import 'package:applovin_admob_sdk/src/widget/debug_ad_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the collapsible debug pill/panel: enabled gating, the process-wide
/// [DebugAdOverlay.globallyVisible] toggle, and the expand/collapse tap flow.
void main() {
  tearDown(() {
    DebugAdOverlay.globallyVisible.value = true;
  });

  Widget harness({bool enabled = true}) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Text('host content'),
            DebugAdOverlay(enabled: enabled),
          ],
        ),
      ),
    );
  }

  testWidgets('enabled: false renders nothing', (tester) async {
    await tester.pumpWidget(harness(enabled: false));
    await tester.pump();

    expect(find.text('🐛 Ad'), findsNothing);
    expect(find.text('🐛 Ad SDK Debug'), findsNothing);
  });

  testWidgets('enabled: true (kDebugMode) shows the collapsed pill',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('🐛 Ad'), findsOneWidget);
    expect(find.text('🐛 Ad SDK Debug'), findsNothing);
  });

  testWidgets('tapping the pill expands the panel', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();

    expect(find.text('🐛 Ad SDK Debug'), findsOneWidget);
    expect(find.text('🐛 Ad'), findsNothing);
    expect(find.text('(no adapter)'), findsOneWidget);
    expect(find.textContaining('Safety:'), findsOneWidget);
    expect(find.textContaining('VIP='), findsOneWidget);
  });

  testWidgets('tapping the close icon collapses back to the pill',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();
    expect(find.text('🐛 Ad SDK Debug'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('🐛 Ad SDK Debug'), findsNothing);
    expect(find.text('🐛 Ad'), findsOneWidget);
  });

  testWidgets('globallyVisible = false hides the overlay even if enabled',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(find.text('🐛 Ad'), findsOneWidget);

    DebugAdOverlay.globallyVisible.value = false;
    await tester.pump();

    expect(find.text('🐛 Ad'), findsNothing);
    expect(find.text('🐛 Ad SDK Debug'), findsNothing);

    DebugAdOverlay.globallyVisible.value = true;
    await tester.pump();
    expect(find.text('🐛 Ad'), findsOneWidget);
  });
}
