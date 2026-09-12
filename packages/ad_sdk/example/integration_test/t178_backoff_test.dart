import 'package:applovin_admob_sdk/src/state/backoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('backoff remains capped at high failure counts', (tester) async {
    const backoff = Backoff();
    expect(backoff.compute(1), 15000);
    expect(backoff.compute(63), backoff.maxMs);
    expect(backoff.compute(1000), backoff.maxMs);
  });
}
