// Widget tests for ShimmerView (T11 gap) — zero coverage previously.

import 'package:applovin_admob_sdk/src/widget/shimmer_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders a ShaderMask sized box without throwing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ShimmerView(cornerRadius: 8, width: 320, height: 50),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ShaderMask), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('animates over time without throwing', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ShimmerView(cornerRadius: 8, width: 320, height: 50),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'removing from the tree disposes the AnimationController/Ticker'
      ' cleanly (no leaked-ticker failure at test teardown)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ShimmerView(cornerRadius: 8, width: 320, height: 50),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // Swap the whole tree for something else — forces State.dispose() on
    // _ShimmerViewState. flutter_test itself fails the test if any Ticker
    // survives past this point, so a clean pump here is the leak check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });
}
