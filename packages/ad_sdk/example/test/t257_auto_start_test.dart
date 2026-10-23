import 'package:ad_sdk_example/t257_profile_frame_benchmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  ValueNotifier<bool> canStart,
  bool autoStart,
  VoidCallback onStart,
) => MaterialApp(
  home: Scaffold(
    body: T257StartGate(
      canStart: canStart,
      autoStart: autoStart,
      onStart: onStart,
    ),
  ),
);

void main() {
  testWidgets('manual mode: no start before ready, tap starts once', (
    tester,
  ) async {
    final canStart = ValueNotifier(false);
    var starts = 0;
    await tester.pumpWidget(_host(canStart, false, () => starts++));

    await tester.tap(find.text('Start benchmark'), warnIfMissed: false);
    expect(starts, 0);

    canStart.value = true;
    await tester.pump();
    expect(starts, 0, reason: 'manual mode never auto-starts');

    await tester.tap(find.text('Start benchmark'));
    await tester.pump();
    await tester.tap(find.text('Start benchmark'), warnIfMissed: false);
    expect(starts, 1);
  });

  testWidgets('auto mode: waits for ready, then starts exactly once', (
    tester,
  ) async {
    final canStart = ValueNotifier(false);
    var starts = 0;
    await tester.pumpWidget(_host(canStart, true, () => starts++));
    expect(starts, 0);

    canStart.value = true;
    await tester.pump();
    expect(starts, 1);

    canStart.value = false;
    canStart.value = true;
    await tester.pump();
    await tester.tap(find.text('Start benchmark'), warnIfMissed: false);
    expect(starts, 1);
  });

  testWidgets('auto mode: already-ready on mount starts once', (tester) async {
    final canStart = ValueNotifier(true);
    var starts = 0;
    await tester.pumpWidget(_host(canStart, true, () => starts++));
    await tester.pump();
    expect(starts, 1);
  });

  testWidgets('semantics action starts in manual mode only when enabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final canStart = ValueNotifier(false);
    var starts = 0;
    await tester.pumpWidget(_host(canStart, false, () => starts++));
    final disabled = tester.getSemantics(
      find.bySemanticsLabel('t267-start-benchmark'),
    );
    expect(disabled.flagsCollection.isEnabled.toString(), 'Tristate.isFalse');

    canStart.value = true;
    await tester.pump();
    tester.semantics.tap(find.semantics.byLabel('t267-start-benchmark'));
    await tester.pump();
    expect(starts, 1);
    handle.dispose();
  });
}
