// Unit tests for T93's pure experimentBucket hash function. AdManager-level
// wiring (GAID vs install-id fallback) is covered separately in
// ad_manager_core_test.dart / ad_preferences_test.dart.

import 'package:applovin_admob_sdk/src/utils/experiment_bucket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same (installId, key, buckets) always returns the same bucket', () {
    final results = List.generate(
        20, (_) => experimentBucket('device-123', 'my_experiment', buckets: 2));
    expect(results.toSet(), hasLength(1),
        reason: 'deterministic — must never flap between calls');
  });

  test('result always falls inside [0, buckets)', () {
    for (var buckets = 1; buckets <= 10; buckets++) {
      final b = experimentBucket('device-abc', 'key', buckets: buckets);
      expect(b, greaterThanOrEqualTo(0));
      expect(b, lessThan(buckets));
    }
  });

  test('different installId can land in a different bucket', () {
    // Not guaranteed for every pair, but true often enough with a real hash
    // that a fixed sample of installIds should not all collide into one
    // bucket — a sanity check against an accidentally-constant hash.
    final buckets = <int>{};
    for (var i = 0; i < 50; i++) {
      buckets.add(experimentBucket('device-$i', 'my_experiment', buckets: 2));
    }
    expect(buckets, {0, 1},
        reason: '50 distinct installIds into 2 buckets must use both — a '
            'hash that always returns 0 would silently break every A/B test');
  });

  test('different key can land the SAME installId in a different bucket',
      () {
    // A host running two concurrent experiments must not have their outcomes
    // fully correlated (same install always bucket 0 of every experiment).
    final a = experimentBucket('device-xyz', 'experiment_a', buckets: 2);
    final b = experimentBucket('device-xyz', 'experiment_b', buckets: 2);
    // Not asserting a != b for this one pair (that WOULD be flaky — could
    // legitimately collide) — just that the key is actually part of the
    // hash input at all, checked across many keys below.
    final distinctBuckets = <int>{};
    for (var i = 0; i < 50; i++) {
      distinctBuckets
          .add(experimentBucket('device-xyz', 'experiment_$i', buckets: 2));
    }
    expect(distinctBuckets, {0, 1},
        reason: 'key must actually affect the hash, not just installId');
    expect(a, isA<int>());
    expect(b, isA<int>());
  });

  test('buckets <= 0 throws ArgumentError', () {
    expect(() => experimentBucket('d', 'k', buckets: 0), throwsArgumentError);
    expect(
        () => experimentBucket('d', 'k', buckets: -1), throwsArgumentError);
  });
}
