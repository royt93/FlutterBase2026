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

  test('CTR threshold accepts the 1.0 boundary value', () {
    final mergedOne =
        applyRemoteSafetyOverrides(local, {'suspiciousCtrThreshold': 1.0});
    expect(mergedOne.suspiciousCtrThreshold, 1.0);
  });

  // Round-31 audit (MINOR) — 0.0 means "any click at all is suspicious for
  // every user", only reachable in practice via a backend serialization bug
  // (a missing field defaulting to `0`), not a deliberate setting. Unlike
  // the two int throttle fields (`min: 1`), this double field had no floor
  // at all before.
  test('a 0.0 CTR threshold is rejected, local value kept', () {
    final merged =
        applyRemoteSafetyOverrides(local, {'suspiciousCtrThreshold': 0.0});
    expect(merged.suspiciousCtrThreshold, local.suspiciousCtrThreshold);
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

  // Round-31 audit (MAJOR) — `double.infinity == double.infinity
  // .truncateToDouble()` is true, so this used to reach `.toInt()`, which
  // throws `UnsupportedError` for Infinity/-Infinity/NaN instead of
  // returning a value — crashing the caller rather than rejecting the
  // field like every other malformed value here.
  test('an Infinity double does not throw and is rejected for an int field',
      () {
    late AdSafetyParams merged;
    expect(
        () => merged = applyRemoteSafetyOverrides(
            local, {'maxFullscreenAdsPerDay': double.infinity}),
        returnsNormally);
    expect(merged.maxFullscreenAdsPerDay, local.maxFullscreenAdsPerDay);
  });

  test('a NaN double does not throw and is rejected for an int field', () {
    late AdSafetyParams merged;
    expect(
        () => merged = applyRemoteSafetyOverrides(
            local, {'minTimeBetweenFullscreenAds': double.nan}),
        returnsNormally);
    expect(merged.minTimeBetweenFullscreenAds,
        local.minTimeBetweenFullscreenAds);
  });

  // Round-31 audit (MINOR) — T126's network-fatigue fields had `copyWith`
  // support in AdSafetyParams but were never read here, so a mediation
  // incident (one network winning repeatedly) had no remote-tunable knob.
  group('T126 network-fatigue fields are remote-tunable', () {
    test('maxSameNetworkShowsPerWindow accepted within range', () {
      final merged = applyRemoteSafetyOverrides(
          local, {'maxSameNetworkShowsPerWindow': 2});
      expect(merged.maxSameNetworkShowsPerWindow, 2);
    });

    test('networkFatigueWindowMs accepted within range', () {
      final merged =
          applyRemoteSafetyOverrides(local, {'networkFatigueWindowMs': 60000});
      expect(merged.networkFatigueWindowMs, 60000);
    });

    test('networkFatigueWindowMs of 0 rejected (would disable the guard)',
        () {
      final merged =
          applyRemoteSafetyOverrides(local, {'networkFatigueWindowMs': 0});
      expect(merged.networkFatigueWindowMs, local.networkFatigueWindowMs);
    });
  });
}
