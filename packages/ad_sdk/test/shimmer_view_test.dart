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

  testWidgets(
      'T257: multiple ShimmerViews dynamically react to active flag toggle',
      (tester) async {
    bool active = false;
    late StateSetter updateState;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          updateState = setState;
          return Scaffold(
            body: Column(
              children: [
                ShimmerView(
                  cornerRadius: 2,
                  width: 20,
                  height: 13,
                  active: active,
                ),
                ShimmerView(
                  cornerRadius: 0,
                  width: 320,
                  height: 50,
                  active: active,
                ),
              ],
            ),
          );
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // When inactive, neither shimmer renders a ShaderMask
    expect(find.byType(ShaderMask), findsNothing);

    // When activated, both shimmers mount ShaderMasks
    updateState(() => active = true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ShaderMask), findsNWidgets(2));
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

  // The first pumpWidget never builds while frames are off, but an ancestor
  // rebuild + pump() still does: that mounts a brand new ShimmerView while the
  // binding reports `hidden`, which is exactly what D1 is about.
  testWidgets('T257: mounted while app is hidden does not animate until resume',
      (tester) async {
    var show = false;
    late StateSetter toggle;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          toggle = setState;
          return Scaffold(
            body: show
                ? const ShimmerView(cornerRadius: 4, width: 300, height: 60)
                : const SizedBox(),
          );
        },
      ),
    ));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    toggle(() => show = true);
    await tester.pump();

    final state = tester.state(find.byType(ShimmerView)) as dynamic;
    expect(state.debugIsAnimating, isFalse,
        reason: 'D1: initState must read the current lifecycleState');
    expect(find.byType(ShaderMask), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(state.debugIsAnimating, isTrue);
    expect(find.byType(ShaderMask), findsOneWidget);
  });

  testWidgets('T257: mounted while app is inactive keeps animating (D2)',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ShimmerView(cornerRadius: 4, width: 300, height: 60),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    final state = tester.state(find.byType(ShimmerView)) as dynamic;
    expect(state.debugIsAnimating, isTrue,
        reason: 'inactive also fires while the app is still visible '
            '(split-screen, notification shade); the shimmer must keep moving');
    expect(find.byType(ShaderMask), findsOneWidget);
  });

  testWidgets('T257: inactive does not stop the ticker, hidden does',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ShimmerView(cornerRadius: 4, width: 300, height: 60),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final state = tester.state(find.byType(ShimmerView)) as dynamic;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(state.debugIsAnimating, isTrue);
    expect(find.byType(ShaderMask), findsOneWidget);

    state.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(state.debugIsAnimating, isFalse);

    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(state.debugIsAnimating, isTrue);
  });

  testWidgets(
      'T257: rebuild while backgrounded restores ShaderMask upon resume without setState',
      (tester) async {
    int counter = 0;
    late StateSetter bump;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          bump = setState;
          return Scaffold(
            body: Column(
              children: [
                Text('counter=$counter'),
                // Non-const on purpose: a const instance is never rebuilt
                // by its parent, so build() would not run while backgrounded.
                ShimmerView(cornerRadius: 4, width: 300.0 + counter, height: 60),
              ],
            ),
          );
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ShaderMask), findsOneWidget);

    // Drive the State directly: paused/hidden disable frames in flutter_test,
    // yet a real device can still rebuild an ancestor around such a transition.
    final state = tester.state(find.byType(ShimmerView)) as dynamic;
    state.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump();

    // Ancestor rebuilds while backgrounded -> build() falls into static Container
    bump(() => counter++);
    await tester.pump();
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.text('counter=1'), findsOneWidget);

    // App resumes -> must re-attach ShaderMask even without State.setState()
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      find.byType(ShaderMask),
      findsOneWidget,
      reason:
          'ShimmerView must re-render ShaderMask when resumed after a background rebuild',
    );
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
