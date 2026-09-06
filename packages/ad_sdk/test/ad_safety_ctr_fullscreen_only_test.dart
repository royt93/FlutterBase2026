// Round-39 audit (claude-cli independent review), MAJOR-2 — the CTR
// anti-fraud gate in `canShowFullscreenAd()` computed its ratio from
// `_totalClicks / _totalImpressions`, and ALL four ad types (banner, MREC,
// native, fullscreen) fed the same shared counters. A banner refreshing every
// 30-60s racks up impressions continuously, diluting the ratio — so a bot
// clicking ONLY fullscreen ads (the higher-value target) could slip under
// the detection threshold that would otherwise catch it, while a legitimate
// app with heavy banner traffic and zero fullscreen fraud stayed unaffected
// only by coincidence of scale, not by design.
//
// Fix: the gate now tracks fullscreen impressions/clicks separately from
// inline (banner/MREC/native) ones, so inline ad traffic can never dilute
// the fullscreen fraud signal.

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
        minTimeBetweenFullscreenAds: 0, // isolate the CTR gate from throttle
      ),
    );
    AdSafetyConfig.resetForReinit();
  });

  test(
      'heavy banner impressions + clicks must never dilute the fullscreen '
      'CTR gate — clicking only fullscreen ads still trips it', () {
    // A bot clicks every banner refresh too, at a LOW ratio (10 clicks over
    // 200 impressions = 5%, well under the 50% threshold) — this must never
    // move the fullscreen gate's own ratio, in either direction.
    for (var i = 0; i < 200; i++) {
      AdSafetyConfig.recordBannerImpression();
    }
    for (var i = 0; i < 10; i++) {
      AdSafetyConfig.recordAdClick(); // inline click, NOT fullscreen
    }

    // Now the actual attack: 5 fullscreen impressions, 5 fullscreen clicks —
    // 100% fullscreen CTR, way above the 50% threshold.
    for (var i = 0; i < 5; i++) {
      AdSafetyConfig.recordFullscreenAdShown();
    }
    for (var i = 0; i < 5; i++) {
      AdSafetyConfig.recordAdClick(fullscreen: true);
    }

    final result = AdSafetyConfig.canShowFullscreenAd();
    expect(result.canShow, isFalse,
        reason: '100% fullscreen CTR must trip the gate regardless of how '
            'much unrelated, low-ratio banner traffic happened alongside it');
    expect(result.reason.toLowerCase(), contains('ctr'),
        reason: 'must be blocked BECAUSE of the CTR anomaly specifically, '
            'not some other gate (throttle/session/caps)');
  });

  test(
      'heavy fullscreen impressions with zero fullscreen clicks must not be '
      'diluted into a false trip by unrelated inline clicks', () {
    for (var i = 0; i < 5; i++) {
      AdSafetyConfig.recordFullscreenAdShown();
    }
    // Inline clicks only — a legitimate banner tap, never a fullscreen one.
    for (var i = 0; i < 15; i++) {
      AdSafetyConfig.recordAdClick();
    }

    final result = AdSafetyConfig.canShowFullscreenAd();
    expect(result.canShow, isTrue,
        reason: 'inline (banner/MREC/native) clicks must never count toward '
            'the fullscreen-only CTR ratio');
  });
}
