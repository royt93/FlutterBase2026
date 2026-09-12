import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const harness = AdStressHarness();

  test('10k events stay within the bounded buffer', () {
    final report = harness.run(events: 10000, maxBufferedEvents: 64);
    expect(report.generated, 10000);
    expect(report.maxBuffered, lessThanOrEqualTo(64));
    expect(report.withinBound, isTrue);
    expect(report.dropped, greaterThan(0));
  });

  test('zero events and lifecycle counters are deterministic', () {
    final report =
        harness.run(events: 0, routeTransitions: 4, reinitializations: 2);
    expect(report.processed, 0);
    expect(report.dropped, 0);
    expect(report.routeTransitions, 4);
    expect(report.reinitializations, 2);
  });

  test('invalid buffer/negative values fail fast', () {
    expect(() => harness.run(maxBufferedEvents: 0), throwsArgumentError);
    expect(() => harness.run(events: -1), throwsArgumentError);
  });
}
