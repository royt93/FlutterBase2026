// Widget test for the Log viewer demo page's real-world critical-log bypass:
// SafeLogger.critical() (R12-A's dryRun release-guard channel, backed by
// e(bypassLevel: true)) must still reach a host's onLog sink — and therefore
// still render in a log-viewer UI — even when the host silenced everything
// via AdLogLevel.none. LogBuffer.instance.sink is exactly the kind of onLog
// consumer a host would wire up (see example/lib/main.dart's LogBuffer),
// so this exercises the bypass through a real UI consumer instead of only
// the unit-level captured list in safe_logger_test.dart.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    LogBuffer.instance.clear();
  });

  tearDown(() {
    LogBuffer.instance.clear();
    SafeLogger.resetForTest();
  });

  Future<void> pumpLogViewer(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LogViewerDemoPage()));
  }

  testWidgets('shows (no logs yet) when the buffer is empty', (tester) async {
    await pumpLogViewer(tester);

    expect(find.text('(no logs yet)'), findsOneWidget);
  });

  testWidgets(
      'critical() still renders in the viewer even when logLevel is none',
      (tester) async {
    SafeLogger.configure(
      level: AdLogLevel.none,
      onLog: LogBuffer.instance.sink,
    );

    SafeLogger.critical('AdSafety', 'dryRun forced off in release');
    await pumpLogViewer(tester);

    expect(find.text('(no logs yet)'), findsNothing);
    expect(find.text('ERROR'), findsOneWidget);
    expect(
        find.text('[AdSafety] dryRun forced off in release'), findsOneWidget);
  });

  testWidgets('a plain e() call is dropped by the sink when logLevel is none',
      (tester) async {
    SafeLogger.configure(
      level: AdLogLevel.none,
      onLog: LogBuffer.instance.sink,
    );

    SafeLogger.e('AdSafety', 'should not appear');
    await pumpLogViewer(tester);

    expect(find.text('(no logs yet)'), findsOneWidget);
  });
}
