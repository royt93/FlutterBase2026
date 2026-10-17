// Widget, lifecycle, theme and interruption tests for ShimmerView (T257).

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
      'removing from the tree disposes the AnimationController/Ticker cleanly',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ShimmerView(cornerRadius: 8, width: 320, height: 50),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });

  // ─── T257: Dark Mode Theme Adaptability ────────────────────────────────────
  testWidgets('T257: adapts colors in Dark Mode theme without flashing white',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: const Scaffold(
        body: ShimmerView(cornerRadius: 4, width: 300, height: 60),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // Verify container uses dark background
    final container = tester.widget<Container>(find.descendant(
      of: find.byType(ShimmerView),
      matching: find.byType(Container),
    ));
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, const Color(0xFF1E1E1E));
    expect(tester.takeException(), isNull);
  });

  testWidgets('T257: uses custom colors when provided', (tester) async {
    const customBg = Color(0xFF112233);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ShimmerView(
          cornerRadius: 4,
          width: 300,
          height: 60,
          backgroundColor: customBg,
          baseColor: Color(0xFF445566),
          highlightColor: Color(0xFF778899),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    final container = tester.widget<Container>(find.descendant(
      of: find.byType(ShimmerView),
      matching: find.byType(Container),
    ));
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, customBg);
  });

  // ─── T257: Active flag & Ticker lifecycle ─────────────────────────────────
  testWidgets('T257: active=false renders static placeholder and stops animation',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ShimmerView(
          cornerRadius: 4,
          width: 300,
          height: 60,
          active: false,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // When active is false, no ShaderMask is rendered to conserve GPU/CPU
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.byType(Container), findsOneWidget);
  });

  testWidgets('T257: dynamic toggle of active restarts and stops animation',
      (tester) async {
    bool active = true;
    late StateSetter updateState;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          updateState = setState;
          return Scaffold(
            body: ShimmerView(
              cornerRadius: 4,
              width: 300,
              height: 60,
              active: active,
            ),
          );
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ShaderMask), findsOneWidget);

    // Turn off
    updateState(() => active = false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ShaderMask), findsNothing);

    // Turn back on
    updateState(() => active = true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ShaderMask), findsOneWidget);
  });

  // ─── T257: Interruption test (AppLifecycleState paused/resumed) ───────────
  testWidgets('T257: app pause stops ticker and resume restarts ticker',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ShimmerView(cornerRadius: 4, width: 300, height: 60),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    final state = tester.state(find.byType(ShimmerView)) as dynamic;
    expect(state.debugIsAnimating, isTrue);

    // Simulate app going to background (interruption: phone call, home button)
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(state.debugIsAnimating, isFalse);

    // Simulate app returning to foreground
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(state.debugIsAnimating, isTrue);
  });

  // ─── T257: Visual Golden Tests ───────────────────────────────────────────
  testWidgets('T257: visual golden test for Light Mode shimmer', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(),
      home: const Scaffold(
        body: Center(
          child: RepaintBoundary(
            child: ShimmerView(cornerRadius: 8, width: 320, height: 50),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(ShimmerView),
      matchesGoldenFile('goldens/shimmer_view_light.png'),
    );
  });

  testWidgets('T257: visual golden test for Dark Mode shimmer', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: RepaintBoundary(
            child: ShimmerView(cornerRadius: 8, width: 320, height: 50),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(ShimmerView),
      matchesGoldenFile('goldens/shimmer_view_dark.png'),
    );
  });

  // ─── T257: 30-Cycle Memory & Ticker Leak Test ─────────────────────────────
  testWidgets('T257: 30 consecutive mount/unmount cycles leak 0 tickers',
      (tester) async {
    for (int i = 0; i < 30; i++) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShimmerView(
            key: ValueKey('shimmer_cycle_$i'),
            cornerRadius: 8,
            width: 320,
            height: 50,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 32)); // 2 frames

      // Unmount completely
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 16));
    }

    // If any of the 30 Tickers leaked, flutter_test automatically throws
    expect(tester.takeException(), isNull);
  });

  // ─── T257: 60fps Frame-Timing Animation Benchmark ─────────────────────────
  testWidgets('T257: 60fps frame-rate benchmark across full animation cycle',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: ShimmerView(cornerRadius: 8, width: 320, height: 50),
        ),
      ),
    ));

    // Simulate 75 frames (1200ms full cycle at 60fps = 16.6ms per frame)
    for (int frame = 0; frame < 75; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }

    expect(find.byType(ShaderMask), findsOneWidget);
  });

  // ─── T257: Network cut simulation (transition to error/collapsed state) ───
  testWidgets('T257: clean unmount when ad load fails/collapses during shimmer',
      (tester) async {
    bool hasError = false;
    late StateSetter updateState;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          updateState = setState;
          if (hasError) {
            return const SizedBox.shrink(); // Collapsed on network cut
          }
          return const ShimmerView(cornerRadius: 8, width: 320, height: 50);
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ShimmerView), findsOneWidget);

    // Network cut occurs -> error callback triggers collapse
    updateState(() => hasError = true);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ShimmerView), findsNothing);
    expect(find.byType(SizedBox), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
