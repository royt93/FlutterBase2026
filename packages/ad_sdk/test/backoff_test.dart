import 'package:applovin_admob_sdk/src/state/backoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backoff.compute', () {
    test('returns zero for no failures and negative input', () {
      const backoff = Backoff(baseMs: 1000, maxMs: 60000);

      expect(backoff.compute(0), 0);
      expect(backoff.compute(-1), 0);
      expect(backoff.compute(-1000), 0);
    });

    test('follows the exponential curve for the first retries', () {
      const backoff = Backoff(baseMs: 1000, maxMs: 60000);

      expect(backoff.compute(1), 1000);
      expect(backoff.compute(2), 2000);
      expect(backoff.compute(3), 4000);
      expect(backoff.compute(4), 8000);
    });

    test('caps at maxMs before integer overflow can occur', () {
      const backoff = Backoff();

      expect(backoff.compute(7), 960000);
      expect(backoff.compute(8), backoff.maxMs);
      expect(backoff.compute(51), backoff.maxMs);
      expect(backoff.compute(63), backoff.maxMs);
      expect(backoff.compute(1000), backoff.maxMs);
    });

    test('supports a zero-duration configuration without throwing', () {
      const backoff = Backoff(baseMs: 0, maxMs: 0);

      expect(backoff.compute(1), 0);
      expect(backoff.compute(1000), 0);
    });
  });
}
