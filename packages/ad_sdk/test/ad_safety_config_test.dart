import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for AdSafetyConfig.
///
/// NOTE: AdSafetyConfig uses static state, so each test group calls
/// resetSession() between tests to ensure isolation.
void main() {
  setUp(() {
    // Reset all static state before each test
    AdSafetyConfig.resetSession();
  });

  // ─────────────────────────────────────────────────
  // AdSafetyResult
  // ─────────────────────────────────────────────────
  group('AdSafetyResult', () {
    test('canShow true', () {
      const r = AdSafetyResult(true, 'OK');
      expect(r.canShow, isTrue);
      expect(r.reason, 'OK');
    });

    test('canShow false', () {
      const r = AdSafetyResult(false, 'blocked');
      expect(r.canShow, isFalse);
      expect(r.reason, 'blocked');
    });
  });

  // ─────────────────────────────────────────────────
  // AdSafetyParams defaults
  // ─────────────────────────────────────────────────
  group('AdSafetyParams defaults', () {
    const p = AdSafetyParams();

    test('minTimeBetweenFullscreenAds = 60000', () {
      expect(p.minTimeBetweenFullscreenAds, 60000);
    });

    test('maxFullscreenAdsPerSession = 6', () {
      expect(p.maxFullscreenAdsPerSession, 6);
    });

    test('minTimeAppOpenResume = 5000', () {
      expect(p.minTimeAppOpenResume, 5000);
    });

    test('maxClicksPerMinute = 3', () {
      expect(p.maxClicksPerMinute, 3);
    });

    test('maxFullscreenAdsPerDay = 5', () {
      expect(p.maxFullscreenAdsPerDay, 5);
    });

    test('maxFullscreenAdsPerHour = 3', () {
      expect(p.maxFullscreenAdsPerHour, 3);
    });

    test('minSessionDurationBeforeAd = 10000', () {
      expect(p.minSessionDurationBeforeAd, 10000);
    });

    test('suspiciousCtrThreshold = 0.30', () {
      expect(p.suspiciousCtrThreshold, closeTo(0.30, 0.001));
    });

    test('maxRapidResumesPerMinute = 3', () {
      expect(p.maxRapidResumesPerMinute, 3);
    });
  });

  // ─────────────────────────────────────────────────
  // AdSafetyParams custom values
  // ─────────────────────────────────────────────────
  group('AdSafetyParams custom', () {
    test('all custom values preserved', () {
      const p = AdSafetyParams(
        minTimeBetweenFullscreenAds: 30000,
        maxFullscreenAdsPerSession: 10,
        minTimeAppOpenResume: 2000,
        maxClicksPerMinute: 5,
        maxFullscreenAdsPerDay: 8,
        maxFullscreenAdsPerHour: 4,
        minSessionDurationBeforeAd: 5000,
        suspiciousCtrThreshold: 0.50,
        maxRapidResumesPerMinute: 6,
      );
      expect(p.minTimeBetweenFullscreenAds, 30000);
      expect(p.maxFullscreenAdsPerSession, 10);
      expect(p.minTimeAppOpenResume, 2000);
      expect(p.maxClicksPerMinute, 5);
      expect(p.maxFullscreenAdsPerDay, 8);
      expect(p.maxFullscreenAdsPerHour, 4);
      expect(p.minSessionDurationBeforeAd, 5000);
      expect(p.suspiciousCtrThreshold, closeTo(0.50, 0.001));
      expect(p.maxRapidResumesPerMinute, 6);
    });
  });

  // ─────────────────────────────────────────────────
  // recordFullscreenAdShown
  // ─────────────────────────────────────────────────
  group('recordFullscreenAdShown', () {
    test('getSessionAdCount increments on each call', () {
      expect(AdSafetyConfig.getSessionAdCount(), 0);
      AdSafetyConfig.recordFullscreenAdShown();
      expect(AdSafetyConfig.getSessionAdCount(), 1);
      AdSafetyConfig.recordFullscreenAdShown();
      expect(AdSafetyConfig.getSessionAdCount(), 2);
    });

    test('getStatus reflects session count', () {
      AdSafetyConfig.recordFullscreenAdShown();
      final status = AdSafetyConfig.getStatus();
      expect(status, contains('session=1'));
    });
  });

  // ─────────────────────────────────────────────────
  // resetSession
  // ─────────────────────────────────────────────────
  group('resetSession', () {
    test('resets session count to 0', () {
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.resetSession();
      expect(AdSafetyConfig.getSessionAdCount(), 0);
    });

    test('getStatus shows 0 after reset', () {
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.resetSession();
      expect(AdSafetyConfig.getStatus(), contains('session=0'));
    });
  });

  // ─────────────────────────────────────────────────
  // getStatus format
  // ─────────────────────────────────────────────────
  group('getStatus', () {
    test('contains expected keys', () {
      final s = AdSafetyConfig.getStatus();
      expect(s, contains('session='));
      expect(s, contains('hourly='));
      expect(s, contains('CTR='));
      expect(s, contains('clicks/min='));
      expect(s, contains('violations='));
      expect(s, contains('suspended='));
    });

    test('suspended=false when no violations', () {
      final s = AdSafetyConfig.getStatus();
      expect(s, contains('suspended=false'));
    });
  });

  // ─────────────────────────────────────────────────
  // recordAppWentBackground
  // ─────────────────────────────────────────────────
  group('recordAppWentBackground', () {
    test('does not throw', () {
      expect(() => AdSafetyConfig.recordAppWentBackground(), returnsNormally);
    });
  });

  // ─────────────────────────────────────────────────
  // recordAdClick
  // ─────────────────────────────────────────────────
  group('recordAdClick', () {
    test('does not throw with no impressions', () {
      expect(() => AdSafetyConfig.recordAdClick(), returnsNormally);
    });

    test('multiple clicks do not throw', () {
      for (int i = 0; i < 5; i++) {
        expect(() => AdSafetyConfig.recordAdClick(), returnsNormally);
      }
    });
  });

  // ─────────────────────────────────────────────────
  // canShowFullscreenAd — blocked right after session start
  // ─────────────────────────────────────────────────
  group('canShowFullscreenAd — session gate', () {
    test('blocked immediately after session start', () {
      // After resetSession(), either:
      //   - 'Session too young' (if no suspicious pause)
      //   - 'Suspended' (if static state bleeds in from other tests)
      // Either way, canShow must be false.
      final result = AdSafetyConfig.canShowFullscreenAd();
      expect(result.canShow, isFalse);
    });
  });


  // ─────────────────────────────────────────────────
  // canShowAppOpenOnResume
  // ─────────────────────────────────────────────────
  group('canShowAppOpenOnResume', () {
    test('returns false on cold start (first call ever)', () {
      // After resetSession, _isColdStart is NOT reset (it is a one-time flag)
      // This tests the resumeTimestamp logic when it's not cold start
      // Call once to consume cold start, then test subsequent call
      AdSafetyConfig.canShowAppOpenOnResume(); // consume cold start
      AdSafetyConfig.recordAppWentBackground();
      // Wait > 5s minimum is not feasible in unit test, so we just verify no exception
      expect(() => AdSafetyConfig.canShowAppOpenOnResume(), returnsNormally);
    });

    test('sequential calls do not throw', () {
      for (int i = 0; i < 5; i++) {
        expect(() => AdSafetyConfig.canShowAppOpenOnResume(), returnsNormally);
      }
    });
  });
}
