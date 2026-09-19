// T143 — Zero-shadow dual-provider failover, reduced scope: unlike
// WaterfallTuner.recommendation() (fill-rate x eCPM comparison, needs real
// accumulated data for BOTH providers via pickSessionProvider exploration
// sessions), ProviderFailoverAdvisor tracks a much simpler, purely
// CURRENT-provider signal — N consecutive AdLoadEvent failures in a row —
// so it can recommend failing over WITHOUT ever needing data for the
// provider it recommends switching TO ("zero shadow requests").
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AdLoadEvent _load(bool success, {String providerTag = '[AppLovin]'}) =>
    AdLoadEvent(
      providerTag: providerTag,
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: success,
    );

// AdManager().events is a non-sync broadcast StreamController — listener
// delivery needs at least one microtask turn. Emit, then flush once before
// reading a synchronous getter (a single await after several debugEmit
// calls flushes all of their queued microtasks together).
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
  });

  group('consecutive-failure streak', () {
    test('starts at false with no events', () async {
      final advisor = ProviderFailoverAdvisor(persist: false);
      await advisor.ready;
      expect(advisor.shouldFailoverNextSession, isFalse);
      await advisor.dispose();
    });

    test('fewer failures than threshold — stays false', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 5, persist: false);
      await advisor.ready;
      for (var i = 0; i < 4; i++) {
        AdManager().debugEmit(_load(false));
      }
      await _flush();
      expect(advisor.shouldFailoverNextSession, isFalse);
      await advisor.dispose();
    });

    test('reaches configurable threshold — becomes true', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 3, persist: false);
      await advisor.ready;
      for (var i = 0; i < 3; i++) {
        AdManager().debugEmit(_load(false));
      }
      await _flush();
      expect(advisor.shouldFailoverNextSession, isTrue);
      await advisor.dispose();
    });

    test(
        'intermittent failures (a success breaks the streak) — must NOT '
        'trigger even if total failures reach the threshold', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 3, persist: false);
      await advisor.ready;
      AdManager().debugEmit(_load(false));
      AdManager().debugEmit(_load(false));
      AdManager().debugEmit(_load(true)); // breaks the streak
      AdManager().debugEmit(_load(false));
      AdManager().debugEmit(_load(false));
      await _flush();
      // 4 total failures across the whole run, but never 3 IN A ROW.
      expect(advisor.shouldFailoverNextSession, isFalse);
      await advisor.dispose();
    });

    test('a success after reaching threshold resets the streak', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 3, persist: false);
      await advisor.ready;
      for (var i = 0; i < 3; i++) {
        AdManager().debugEmit(_load(false));
      }
      await _flush();
      expect(advisor.shouldFailoverNextSession, isTrue);
      AdManager().debugEmit(_load(true));
      await _flush();
      expect(advisor.shouldFailoverNextSession, isFalse);
      await advisor.dispose();
    });

    test('non-AdLoadEvent events (e.g. AdRevenueEvent) do not affect the '
        'streak', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 2, persist: false);
      await advisor.ready;
      AdManager().debugEmit(_load(false));
      AdManager().debugEmit(const AdRevenueEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        valueMicros: 1000,
        currencyCode: 'USD',
      ));
      await _flush();
      expect(advisor.shouldFailoverNextSession, isFalse,
          reason: 'only 1 real AdLoadEvent failure has happened');
      AdManager().debugEmit(_load(false));
      await _flush();
      expect(advisor.shouldFailoverNextSession, isTrue);
      await advisor.dispose();
    });

    test(
        'a different provider tag resets the streak — a real provider '
        'switch must not inherit the old provider\'s near-threshold count',
        () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 3, persist: false);
      await advisor.ready;
      AdManager().debugEmit(_load(false, providerTag: '[AppLovin]'));
      AdManager().debugEmit(_load(false, providerTag: '[AppLovin]'));
      // Switched providers (e.g. host acted on a previous recommendation).
      AdManager().debugEmit(_load(false, providerTag: '[AdMob]'));
      await _flush();
      expect(advisor.shouldFailoverNextSession, isFalse,
          reason: 'only 1 consecutive failure for the NEW provider so far');
      await advisor.dispose();
    });
  });

  group('offline mid-flight failures do not count (round 49 audit fix)', () {
    tearDown(() => AdManager().debugConnectivityChanged(true));

    test(
        'a load failure while offline is ignored — does not build a false '
        'failover streak during a network flap', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 3, persist: false);
      await advisor.ready;

      AdManager().debugConnectivityChanged(false);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_load(false));
      }
      await _flush();
      expect(advisor.shouldFailoverNextSession, isFalse,
          reason: 'all 5 failures happened while offline — none of them '
              'should count toward the consecutive-failure streak');

      AdManager().debugConnectivityChanged(true);
      for (var i = 0; i < 3; i++) {
        AdManager().debugEmit(_load(false));
      }
      await _flush();
      expect(advisor.shouldFailoverNextSession, isTrue,
          reason: 'once actually online again, real failures must still '
              'count normally');
      await advisor.dispose();
    });
  });

  group('persistence across restarts', () {
    test('a streak survives dispose() + reconstruction', () async {
      final advisor1 = ProviderFailoverAdvisor(consecutiveFailureThreshold: 3);
      await advisor1.ready;
      AdManager().debugEmit(_load(false));
      AdManager().debugEmit(_load(false));
      await _flush();
      await advisor1.dispose();

      final advisor2 = ProviderFailoverAdvisor(consecutiveFailureThreshold: 3);
      await advisor2.ready;
      expect(advisor2.shouldFailoverNextSession, isFalse,
          reason: 'only 2 of 3 persisted so far');
      AdManager().debugEmit(_load(false));
      await _flush();
      expect(advisor2.shouldFailoverNextSession, isTrue,
          reason: 'the 3rd consecutive failure, across the restart boundary');
      await advisor2.dispose();
    });

    test('persist: false never touches SharedPreferences', () async {
      final advisor1 = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 2, persist: false);
      await advisor1.ready;
      AdManager().debugEmit(_load(false));
      await _flush();
      await advisor1.dispose();

      final advisor2 = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 2, persist: false);
      await advisor2.ready;
      AdManager().debugEmit(_load(false));
      await _flush();
      expect(advisor2.shouldFailoverNextSession, isFalse,
          reason: 'persist:false starts fresh every time, no carryover');
      await advisor2.dispose();
    });
  });

  group('AdManager().applyProviderFailover()', () {
    test('returns the SAME provider when the advisor has not tripped',
        () async {
      final advisor = ProviderFailoverAdvisor(persist: false);
      await advisor.ready;
      final result = AdManager()
          .applyProviderFailover(AdProvider.appLovin, advisor: advisor);
      expect(result, AdProvider.appLovin);
      await advisor.dispose();
    });

    test('returns the OTHER provider once the advisor has tripped',
        () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 2, persist: false);
      await advisor.ready;
      AdManager().debugEmit(_load(false));
      AdManager().debugEmit(_load(false));
      await _flush();
      final result = AdManager()
          .applyProviderFailover(AdProvider.appLovin, advisor: advisor);
      expect(result, AdProvider.admob);
      await advisor.dispose();
    });

    test(
        'does NOT flip a candidate that is already the OTHER provider — '
        'AppLovin failed, the next-session picker already chose AdMob, '
        'the result must stay AdMob, not bounce back to the failing '
        'AppLovin', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 2,
          persist: false); // default providerTag in _load is '[AppLovin]'
      await advisor.ready;
      AdManager().debugEmit(_load(false));
      AdManager().debugEmit(_load(false));
      await _flush();
      expect(advisor.shouldFailoverNextSession, isTrue,
          reason: 'sanity: AppLovin has tripped the streak');

      // pickProviderCohort()/pickSessionProvider() already independently
      // picked AdMob for next session — applying failover on top of that
      // must be a no-op, not flip it back to the provider that just failed.
      final result = AdManager()
          .applyProviderFailover(AdProvider.admob, advisor: advisor);
      expect(result, AdProvider.admob);
      await advisor.dispose();
    });
  });

  group(
      'AdManager().applyProviderFailover() during the half-open probe '
      'window (post-T208 audit fix)', () {
    test(
        'circuitState == open: always fails over, never even consults '
        'allowHalfOpenProbe', () async {
      var now = DateTime(2026, 1, 1);
      final advisor = ProviderFailoverAdvisor(
        consecutiveFailureThreshold: 1,
        persist: false,
        cooldown: const Duration(seconds: 10),
        now: () => now,
      );
      await advisor.ready;
      AdManager().debugEmit(_load(false));
      await _flush();
      expect(advisor.circuitState, ProviderCircuitState.open);

      final result = AdManager()
          .applyProviderFailover(AdProvider.appLovin, advisor: advisor);
      expect(result, AdProvider.admob);
      // The probe slot must still be unclaimed — open never touches it.
      now = now.add(const Duration(seconds: 11));
      expect(advisor.allowHalfOpenProbe(), isTrue);
      await advisor.dispose();
    });

    test(
        'circuitState == halfOpen: the FIRST caller gets the real provider '
        'back (the designated probe), a SECOND concurrent caller in the '
        'same window still fails over — this is the exact bug: the old '
        'code let EVERY caller through during half-open, not just one',
        () async {
      var now = DateTime(2026, 1, 1);
      final advisor = ProviderFailoverAdvisor(
        consecutiveFailureThreshold: 1,
        persist: false,
        cooldown: const Duration(seconds: 10),
        now: () => now,
      );
      await advisor.ready;
      AdManager().debugEmit(_load(false));
      await _flush();
      now = now.add(const Duration(seconds: 11));
      expect(advisor.circuitState, ProviderCircuitState.halfOpen);

      final first = AdManager()
          .applyProviderFailover(AdProvider.appLovin, advisor: advisor);
      expect(first, AdProvider.appLovin,
          reason: 'T208 fix — the designated probe call must get the real '
              '(previously-failing) provider back, not be silently failed '
              'over again');

      final second = AdManager()
          .applyProviderFailover(AdProvider.appLovin, advisor: advisor);
      expect(second, AdProvider.admob,
          reason: 'T208 fix — the probe slot is already claimed; a second '
              'call in the same half-open window must NOT also get the '
              'unverified provider — this is exactly what the old code '
              'got wrong, since it never called allowHalfOpenProbe() at '
              'all and let unlimited callers through');
      await advisor.dispose();
    });

    test(
        'circuitState == closed: always returns the candidate unchanged, '
        'no failover applied', () async {
      final advisor = ProviderFailoverAdvisor(persist: false);
      await advisor.ready;
      expect(advisor.circuitState, ProviderCircuitState.closed);
      final result = AdManager()
          .applyProviderFailover(AdProvider.appLovin, advisor: advisor);
      expect(result, AdProvider.appLovin);
      await advisor.dispose();
    });
  });

  group('T171 — consecutiveFailureThreshold <= 0 falls back to the default '
      'instead of recommending failover with zero real failures', () {
    test('threshold=0 does not immediately read as "should fail over"',
        () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 0, persist: false);
      await advisor.ready;
      expect(advisor.shouldFailoverNextSession, isFalse,
          reason: 'T171 — a misconfigured 0 threshold must not make this '
              'true with zero failures ever recorded');
      expect(advisor.consecutiveFailureThreshold, 5,
          reason: 'substituted the class\'s own documented default');
      await advisor.dispose();
    });

    test('a negative threshold also falls back to the default', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: -3, persist: false);
      await advisor.ready;
      expect(advisor.shouldFailoverNextSession, isFalse);
      expect(advisor.consecutiveFailureThreshold, 5);
      await advisor.dispose();
    });

    test('the substituted default still behaves like a real threshold — '
        'takes exactly 5 consecutive failures to trip', () async {
      final advisor = ProviderFailoverAdvisor(
          consecutiveFailureThreshold: 0, persist: false);
      await advisor.ready;
      for (var i = 0; i < 4; i++) {
        AdManager().debugEmit(_load(false));
      }
      await _flush();
      expect(advisor.shouldFailoverNextSession, isFalse);
      AdManager().debugEmit(_load(false));
      await _flush();
      expect(advisor.shouldFailoverNextSession, isTrue);
      await advisor.dispose();
    });
  });
}
