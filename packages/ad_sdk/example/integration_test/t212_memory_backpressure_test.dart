import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T212 Android smoke: 10k-event backpressure run is bounded',
      (tester) async {
    final report = const AdStressHarness().run(
        events: 10000,
        maxBufferedEvents: 256,
        routeTransitions: 500,
        reinitializations: 50);
    expect(report.withinBound, isTrue);
    expect(report.maxBuffered, lessThanOrEqualTo(256));
  });
}
