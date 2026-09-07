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
}
