// T201 — InlineAdControllerDemoPage: tapping each section's Refresh/Pause/
// Resume buttons must actually reach that section's own InlineAdController
// (not some shared/global one) and the status label must reflect it.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host() => const MaterialApp(home: InlineAdControllerDemoPage());

  testWidgets('renders one section per format with an initially active '
      'status', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.text('Banner'), findsOneWidget);
    expect(find.text('MREC'), findsOneWidget);
    expect(find.text('Native'), findsOneWidget);
    expect(find.text('status: active'), findsNWidgets(3));
  });

  testWidgets('pausing the Banner section only pauses Banner, not '
      'MREC/Native', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    // The Banner section's own "Pause" button — the first one in the list.
    await tester.tap(find.text('Pause').first);
    await tester.pump();

    expect(find.text('status: paused'), findsOneWidget);
    expect(find.text('status: active'), findsNWidgets(2));
  });

  testWidgets('resuming after pausing goes back to active', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    await tester.tap(find.text('Pause').first);
    await tester.pump();
    expect(find.text('status: paused'), findsOneWidget);

    await tester.tap(find.text('Resume').first);
    await tester.pump();
    expect(find.text('status: active'), findsNWidgets(3));
  });

  testWidgets('tapping Refresh does not throw and keeps the section active',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    await tester.tap(find.text('Refresh').first);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('status: active'), findsNWidgets(3));
  });

  testWidgets('disposing the page detaches every controller without '
      'throwing', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
