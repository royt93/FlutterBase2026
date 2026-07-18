// Widget test for the AdEvent stream page rendering ArbitratorNudgeEvent.
//
// EventBuffer is a plain singleton fed by AdManager().events — push a row
// directly (no SDK init needed) and assert the nudge tile renders.

import 'package:ad_sdk_example/main.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => EventBuffer.instance.clear());

  testWidgets('renders an ArbitratorNudgeEvent as NUDGE with trailing eCPM',
      (tester) async {
    EventBuffer.instance.onEvent(const ArbitratorNudgeEvent(
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      estimatedEcpmMicros: 2500000,
    ));

    await tester.pumpWidget(const MaterialApp(home: EventsDemoPage()));

    expect(find.textContaining('NUDGE'), findsOneWidget);
    expect(find.textContaining('vetoed low-eCPM ad'), findsOneWidget);
    expect(find.textContaining('eCPM=\$2.5'), findsOneWidget);
  });
}
