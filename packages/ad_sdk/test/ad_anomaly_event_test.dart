// Unit tests for the anomaly/fraud alert stream (T25).
//
// AdSafetyConfig._triggerSuspiciousPause() must emit exactly one
// AdAnomalyEvent per call via the sink set by setAnomalySink(), carrying the
// same reason/violationCount/pauseDurationMs it already logs internally —
// including when AdSafetyParams.dryRun is true.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<AdAnomalyEvent> captured;

  Future<void> initWith(AdSafetyParams params) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: params);
    AdSafetyConfig.resetForReinit();
    captured = [];
    AdSafetyConfig.setAnomalySink(captured.add);
  }

  group('AdAnomalyEvent — no sink wired', () {
    // Must run before any other test in this file calls setAnomalySink() —
    // the sink is a static field, so this only proves the true null-sink
    // path (e.g. code running before AdManager.initialize() wires one) if
    // nothing upstream has already set it in this isolate.
    test('does not throw when no sink is set', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(
        prefs,
        params: AdSafetyParams.debug.copyWith(suspiciousCtrThreshold: 0.5),
      );
      AdSafetyConfig.resetForReinit();
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordAdClick();
      }
      expect(() => AdSafetyConfig.canShowFullscreenAd(), returnsNormally);
    });
  });

  group('AdAnomalyEvent — CTR anomaly', () {
    test('canShowFullscreenAd emits one event on CTR-over-threshold', () async {
      await initWith(AdSafetyParams.debug.copyWith(
        suspiciousCtrThreshold: 0.5,
      ));

      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordAdClick(); // 100% CTR > 50% threshold
      }

      final result = AdSafetyConfig.canShowFullscreenAd();
      expect(result.canShow, isFalse);

      expect(captured, hasLength(1));
      final event = captured.single;
      expect(event.reason, contains('CTR anomaly'));
      expect(event.violationCount, 1);
      expect(event.pauseDurationMs, 30 * 60 * 1000); // base pause, 1st strike
      expect(event.providerTag, '[Safety]');
      expect(event.type, AdSlotType.interstitial);
      expect(event.placement, AdPlacement.unspecified);
    });

    test('second violation doubles the pause duration (progressive cooldown)',
        () async {
      // canShowFullscreenAd() short-circuits on "still suspended" once a
      // pause is active, so a 2nd CTR check can't re-trigger it in-test
      // (no way to fast-forward DateTime.now()). recordAdClick()'s click-spam
      // branch has no such gate, so use it to drive the 2nd violation instead
      // — progressive cooldown is shared state, so it still doubles.
      await initWith(AdSafetyParams.debug.copyWith(
        suspiciousCtrThreshold: 0.5,
        maxClicksPerMinute: 10, // high enough the CTR setup clicks don't spam
      ));

      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordAdClick(); // 100% CTR > 50% threshold
      }
      AdSafetyConfig.canShowFullscreenAd(); // 1st violation: CTR anomaly

      for (var i = 0; i < 6; i++) {
        AdSafetyConfig.recordAdClick(); // 11 clicks/min total > cap of 10
      }

      expect(captured, hasLength(2));
      expect(captured[0].violationCount, 1);
      expect(captured[0].pauseDurationMs, 30 * 60 * 1000);
      expect(captured[1].violationCount, 2);
      expect(captured[1].pauseDurationMs, 60 * 60 * 1000); // doubled
    });
  });

  group('AdAnomalyEvent — click spam', () {
    test('recordAdClick emits one event once clicks/min exceeds cap', () async {
      await initWith(AdSafetyParams.debug.copyWith(maxClicksPerMinute: 2));

      AdSafetyConfig.recordAdClick();
      AdSafetyConfig.recordAdClick();
      expect(captured, isEmpty); // at the cap, not yet over it

      AdSafetyConfig.recordAdClick(); // 3rd click within the minute > cap
      expect(captured, hasLength(1));
      expect(captured.single.reason, contains('Click spam'));
      expect(captured.single.violationCount, 1);
    });
  });

  group('AdAnomalyEvent — dry-run', () {
    test('still emits even when dryRun bypasses the block', () async {
      await initWith(AdSafetyParams.debug.copyWith(
        suspiciousCtrThreshold: 0.5,
        dryRun: true,
      ));

      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordAdClick();
      }

      final result = AdSafetyConfig.canShowFullscreenAd();
      expect(result.canShow, isTrue); // dry-run bypasses the block itself
      expect(captured, hasLength(1)); // but the anomaly signal still fires
      expect(captured.single.reason, contains('CTR anomaly'));
    });
  });
}
