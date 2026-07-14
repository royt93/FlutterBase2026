// Widget test for the AdEvent stream page rendering AdAnomalyEvent (T25).
//
// EventBuffer is a plain singleton fed by AdManager().events — push a row
// directly (no SDK init needed) and assert the anomaly tile renders.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => EventBuffer.instance.clear());

  testWidgets('shows the empty-state hint when EventBuffer is empty',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: EventsDemoPage()));

    expect(
        find.text('(no events yet — trigger an ad somewhere)'), findsOneWidget);
  });

  testWidgets('renders an AdAnomalyEvent with its reason and violation count',
      (tester) async {
    EventBuffer.instance.onEvent(const AdAnomalyEvent(
      reason: 'CTR anomaly: 100% (threshold: 50%)',
      violationCount: 2,
      pauseDurationMs: 60 * 60 * 1000,
    ));

    await tester.pumpWidget(const MaterialApp(home: EventsDemoPage()));

    expect(find.text('CTR anomaly: 100% (threshold: 50%)'), findsOneWidget);
    expect(find.textContaining('ANOMALY'), findsOneWidget);
    expect(find.textContaining('violation #2'), findsOneWidget);
    expect(find.textContaining('paused 60min'), findsOneWidget);
  });
}
