// Unit tests for AdSafetyConfig's real-time policy risk score (T24).
//
// Additive-only signal — never consulted by canShowFullscreenAd()/getStatus().
// Each test uses a dedicated AdSafetyParams so the CTR/resume thresholds are
// deterministic, then resetForReinit() gives a clean 0-score baseline.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(
      prefs,
      params: AdSafetyParams.debug.copyWith(
        suspiciousCtrThreshold: 0.5,
        maxRapidResumesPerMinute: 3,
      ),
    );
    AdSafetyConfig.resetForReinit();
  });

  group('policyRiskScore baseline', () {
    test('starts at 0 with no activity', () {
      expect(AdSafetyConfig.getPolicyRiskScore(), 0);
      expect(AdSafetyConfig.policyRiskScore.value, 0);
    });
  });

  group('policyRiskScore — CTR component', () {
    test('rises monotonically as click-through ratio increases', () {
      for (var i = 0; i < 20; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      final scoreNoClicks = AdSafetyConfig.getPolicyRiskScore();
      expect(scoreNoClicks, 0);

      var previous = scoreNoClicks;
      for (var i = 0; i < 10; i++) {
        AdSafetyConfig.recordAdClick();
        final current = AdSafetyConfig.getPolicyRiskScore();
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
      expect(previous, greaterThan(scoreNoClicks));
    });

    test(
        'policyRiskScore listenable mirrors getPolicyRiskScore() after a click',
        () {
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      AdSafetyConfig.recordAdClick();
      expect(AdSafetyConfig.policyRiskScore.value,
          AdSafetyConfig.getPolicyRiskScore());
      expect(AdSafetyConfig.policyRiskScore.value, greaterThan(0));
    });
  });

  group('policyRiskScore — violation component', () {
    // T24 re-audit fix: a CTR-anomaly violation's `ctr` value already feeds
    // ctrComponent directly, so the pause it triggers must NOT also inflate
    // violationComponent — that was double-penalising the same signal under
    // two labels. (It still increments the progressive-cooldown counter —
    // see ad_safety_config_test.dart.)
    test('CTR-anomaly suspicious pause does not double-count into the score',
        () {
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordAdClick(); // 100% CTR > 0.5 threshold
      }
      final beforeGate = AdSafetyConfig.getPolicyRiskScore();

      final result = AdSafetyConfig.canShowFullscreenAd(); // triggers pause
      expect(result.canShow, isFalse);

      final afterGate = AdSafetyConfig.getPolicyRiskScore();
      expect(afterGate, beforeGate);
      expect(AdSafetyConfig.policyRiskScore.value, afterGate);
    });

    test(
        'click-spam suspicious pause raises the score via the violation '
        'component', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(
        prefs,
        params: AdSafetyParams.debug.copyWith(maxClicksPerMinute: 2),
      );
      AdSafetyConfig.resetForReinit();

      // No impressions recorded — ctrComponent stays 0, isolating the
      // violation component.
      final before = AdSafetyConfig.getPolicyRiskScore();
      expect(before, 0);

      for (var i = 0; i < 3; i++) {
        AdSafetyConfig.recordAdClick(); // 3rd click > maxClicksPerMinute of 2
      }

      final after = AdSafetyConfig.getPolicyRiskScore();
      expect(after, greaterThan(before));
      expect(AdSafetyConfig.policyRiskScore.value, after);
    });
  });

  group('policyRiskScore — resume-spam component', () {
    test('rapid resumes raise the score without exceeding the cap', () {
      AdSafetyConfig.canShowAppOpenOnResume(); // consume cold start
      final before = AdSafetyConfig.getPolicyRiskScore();

      AdSafetyConfig.canShowAppOpenOnResume();
      final afterOne = AdSafetyConfig.getPolicyRiskScore();
      AdSafetyConfig.canShowAppOpenOnResume();
      final afterTwo = AdSafetyConfig.getPolicyRiskScore();

      expect(afterOne, greaterThanOrEqualTo(before));
      expect(afterTwo, greaterThanOrEqualTo(afterOne));
      expect(afterTwo, greaterThan(before));
      expect(AdSafetyConfig.policyRiskScore.value, afterTwo);
    });
  });

  group('policyRiskScore — reset behavior', () {
    test('resetSession zeroes the CTR and resume components', () {
      for (var i = 0; i < 10; i++) {
        AdSafetyConfig.recordBannerImpression();
        AdSafetyConfig.recordAdClick();
      }
      AdSafetyConfig.canShowAppOpenOnResume();
      AdSafetyConfig.canShowAppOpenOnResume();
      expect(AdSafetyConfig.getPolicyRiskScore(), greaterThan(0));

      AdSafetyConfig.resetSession();
      expect(AdSafetyConfig.getPolicyRiskScore(), 0);
      expect(AdSafetyConfig.policyRiskScore.value, 0);
    });

    test('resetForReinit also zeroes the violation component', () {
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordAdClick();
      }
      AdSafetyConfig.canShowFullscreenAd(); // trigger a violation
      expect(AdSafetyConfig.getPolicyRiskScore(), greaterThan(0));

      AdSafetyConfig.resetForReinit();
      expect(AdSafetyConfig.getPolicyRiskScore(), 0);
      expect(AdSafetyConfig.policyRiskScore.value, 0);
    });
  });

  group('policyRiskScore — bounds', () {
    test('never exceeds 100 under extreme combined signals', () {
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 50; i++) {
        AdSafetyConfig.recordAdClick();
      }
      for (var i = 0; i < 3; i++) {
        AdSafetyConfig.canShowFullscreenAd();
      }
      for (var i = 0; i < 10; i++) {
        AdSafetyConfig.canShowAppOpenOnResume();
      }

      expect(AdSafetyConfig.getPolicyRiskScore(), inInclusiveRange(0, 100));
    });
  });
}
