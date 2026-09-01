// Unit tests for T88's applyRemoteSafetyOverrides — the validation/merge
// logic behind RemoteAdSafetyProvider. AdManager-level wiring (provider
// timeout/failure falls back to local params) is covered separately in
// ad_manager_core_test.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const local = AdSafetyParams(
    maxFullscreenAdsPerDay: 5,
    maxFullscreenAdsPerHour: 3,
    suspiciousCtrThreshold: 0.30,
    dryRun: false,
  );

  test('valid overrides replace the matching local fields', () {
    final merged = applyRemoteSafetyOverrides(local, {
      'maxFullscreenAdsPerDay': 8,
      'suspiciousCtrThreshold': 0.5,
      'dryRun': true,
    });

    expect(merged.maxFullscreenAdsPerDay, 8);
    expect(merged.suspiciousCtrThreshold, 0.5);
    expect(merged.dryRun, isTrue);
    expect(merged.maxFullscreenAdsPerHour, 3,
        reason: 'a field absent from the overrides map keeps the local value');
  });

  test('unknown keys are ignored, not fatal', () {
    final merged = applyRemoteSafetyOverrides(
        local, {'someTypoedFieldName': 999, 'maxFullscreenAdsPerDay': 8});

    expect(merged.maxFullscreenAdsPerDay, 8);
  });

  test('negative int override is rejected, local value kept', () {
    final merged =
        applyRemoteSafetyOverrides(local, {'maxFullscreenAdsPerDay': -1});

    expect(merged.maxFullscreenAdsPerDay, 5,
        reason: 'a negative cap makes no sense and must not reach '
            'AdSafetyConfig');
  });

  test('wrong-typed value is rejected, local value kept', () {
    final merged = applyRemoteSafetyOverrides(
        local, {'maxFullscreenAdsPerDay': 'eight'});

    expect(merged.maxFullscreenAdsPerDay, 5);
  });

  test('CTR threshold outside [0,1] is rejected, local value kept', () {
    final merged =
        applyRemoteSafetyOverrides(local, {'suspiciousCtrThreshold': 1.5});

    expect(merged.suspiciousCtrThreshold, 0.30);
  });

  test('CTR threshold accepts the [0,1] boundary values', () {
    final mergedZero =
        applyRemoteSafetyOverrides(local, {'suspiciousCtrThreshold': 0.0});
    final mergedOne =
        applyRemoteSafetyOverrides(local, {'suspiciousCtrThreshold': 1.0});

    expect(mergedZero.suspiciousCtrThreshold, 0.0);
    expect(mergedOne.suspiciousCtrThreshold, 1.0);
  });

  test('empty overrides map returns local values unchanged', () {
    final merged = applyRemoteSafetyOverrides(local, {});
    expect(merged.maxFullscreenAdsPerDay, local.maxFullscreenAdsPerDay);
    expect(merged.maxFullscreenAdsPerHour, local.maxFullscreenAdsPerHour);
    expect(merged.suspiciousCtrThreshold, local.suspiciousCtrThreshold);
  });

  // Round-30 audit (MAJOR) — only `dryRun` was guarded against a
  // safety-defeating remote payload; these six numeric fields had no
  // ceiling at all.
  group('round-30 audit (MAJOR): remote overrides cannot defeat the safety '
      'layer via an absurd value', () {
    test('a zero throttle is rejected — 0 would kill the anti-fraud '
        'throttle outright', () {
      final merged = applyRemoteSafetyOverrides(
          local, {'minTimeBetweenFullscreenAds': 0});
      expect(merged.minTimeBetweenFullscreenAds,
          local.minTimeBetweenFullscreenAds,
          reason: 'the throttle field must require a real positive floor, '
              'not just >= 0');
    });

    test('a zero minTimeAppOpenResume is rejected', () {
      final merged =
          applyRemoteSafetyOverrides(local, {'minTimeAppOpenResume': 0});
      expect(merged.minTimeAppOpenResume, local.minTimeAppOpenResume);
    });

    test('an absurdly large daily cap is rejected instead of making the '
        'session effectively unlimited', () {
      final merged = applyRemoteSafetyOverrides(
          local, {'maxFullscreenAdsPerDay': 1000000});
      expect(merged.maxFullscreenAdsPerDay, local.maxFullscreenAdsPerDay,
          reason: 'a cap field must have an upper bound — a compromised or '
              'buggy remote payload must not be able to make the daily cap '
              'functionally unlimited');
    });

    test('an absurdly large maxClicksPerMinute is rejected', () {
      final merged =
          applyRemoteSafetyOverrides(local, {'maxClicksPerMinute': 999999});
      expect(merged.maxClicksPerMinute, local.maxClicksPerMinute);
    });

    test('a value just within the ceiling is still accepted', () {
      final merged = applyRemoteSafetyOverrides(
          local, {'maxFullscreenAdsPerDay': 500, 'maxClicksPerMinute': 60});
      expect(merged.maxFullscreenAdsPerDay, 500);
      expect(merged.maxClicksPerMinute, 60);
    });
  });

  // Round-30 audit (MINOR) — posInt used to require `v is int` exactly,
  // unlike unitDouble's more permissive `is num`.
  test('a whole-valued double (e.g. 8.0) is accepted for an int field',
      () {
    final merged =
        applyRemoteSafetyOverrides(local, {'maxFullscreenAdsPerDay': 8.0});
    expect(merged.maxFullscreenAdsPerDay, 8);
  });

  test('a fractional double is rejected for an int field', () {
    final merged =
        applyRemoteSafetyOverrides(local, {'maxFullscreenAdsPerDay': 8.5});
    expect(merged.maxFullscreenAdsPerDay, local.maxFullscreenAdsPerDay);
  });
}
