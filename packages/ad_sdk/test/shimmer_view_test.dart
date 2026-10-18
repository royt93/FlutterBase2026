// Widget, lifecycle, theme and interruption tests for ShimmerView (T257).

import 'dart:ui' as ui;

import 'package:applovin_admob_sdk/src/widget/shimmer_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
        body: RepaintBoundary(
          key: ValueKey('dark-shimmer-pixels'),
          child: ShimmerView(cornerRadius: 4, width: 300, height: 60),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    // Verify container uses dark background
    final container = tester.widget<Container>(find.descendant(
      of: find.byType(ShimmerView),
      matching: find.byType(Container),
    ));
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, const Color(0xFF1E1E1E));

    final renderedCenterPixel = await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('dark-shimmer-pixels')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final width = image.width;
      final height = image.height;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return null;
      final center = ((width ~/ 2) + (height ~/ 2) * width) * 4;
      return data.getUint8(center);
    });
    expect(renderedCenterPixel, greaterThan(30),
        reason: 'rendered shimmer pixel must be brighter than its #1E1E1E base');
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

  // ─── T257: Animation cycle pump simulation ─────────────────────────
  testWidgets('T257: animation cycle pumps 75 frames without throwing',
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

  // ─── T257: Route cover/uncover (Flutter mutes tickers under opaque routes) ─
  testWidgets(
      'T257: opaque route covering a mounted shimmer mutes its ticker, pop resumes',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(
        body: ShimmerView(cornerRadius: 4, width: 300, height: 60),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: 'visible shimmer keeps scheduling frames');

    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: SizedBox()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ShimmerView, skipOffstage: false), findsOneWidget,
        reason: 'covered route stays mounted (maintainState)');
    final shimmerContext =
        tester.element(find.byType(ShimmerView, skipOffstage: false));
    expect(TickerMode.valuesOf(shimmerContext).enabled, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'muted ticker must not schedule frames while covered');

    navKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(TickerMode.valuesOf(shimmerContext).enabled, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: 'uncovered shimmer resumes scheduling frames');
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
