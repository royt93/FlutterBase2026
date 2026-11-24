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

  // Review of the resume-gate change (2026-11-24) — the resume gate now asks the
  // strict show gate WITHOUT recording a violation, so a CTR block on resume
  // never advanced `_ctrPauseTriggeredAtImpressionCount`. The round-31 rule
  // ("skip the CTR gate for the next 5 impressions once it tripped") is the only
  // way out of a stale ratio, and it needs a recorded violation to arm. If every
  // attempt is a resume, nothing ever arms it: a permanent block.
  test('a CTR block on resume is not permanent when only resumes are tried',
      () {
    for (var i = 0; i < 5; i++) {
      AdSafetyConfig.recordFullscreenAdShown();
    }
    for (var i = 0; i < 5; i++) {
      AdSafetyConfig.recordAdClick(fullscreen: true);
    }

    AdSafetyConfig.canShowAppOpenOnResume(); // consumes the cold-start skip
    AdSafetyConfig.recordAppWentBackground();
    final first = AdSafetyConfig.canShowAppOpenOnResume();
    expect(first.canShow, isFalse, reason: 'precondition: CTR blocks resume');
    expect(first.reason.toLowerCase(), contains('ctr'));

    // The user keeps resuming the app; the app never shows another ad. Once the
    // 30-minute invalid-traffic pause that the resume path now arms has run out
    // the CTR gate must let the next attempt through (the round-31 skip).
    AdSafetyConfig.debugExpireSuspiciousPause();
    var unblocked = false;
    for (var i = 0; i < 12; i++) {
      AdSafetyConfig.recordAppWentBackground();
      final r = AdSafetyConfig.canShowAppOpenOnResume();
      if (r.canShow) {
        unblocked = true;
        break;
      }
    }
    expect(unblocked, isTrue,
        reason: 'the resume path must record the violation like every other '
            'show path, or a stale CTR keeps blocking it forever');
  });

  // Review of the resume-gate change: every cap the strict show gate enforces
  // must also stop the resume gate, so the SDK never shows its Loading overlay
  // for an App Open it is about to refuse.
  group('resume gate honours the fullscreen caps', () {
    Future<void> configure(AdSafetyParams params) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: params);
      AdSafetyConfig.resetForReinit();
      AdSafetyConfig.canShowAppOpenOnResume(); // consumes the cold-start skip
      AdSafetyConfig.recordAppWentBackground();
    }

    test('session cap', () async {
      await configure(AdSafetyParams.debug.copyWith(
        minTimeBetweenFullscreenAds: 0,
        maxFullscreenAdsPerSession: 1,
      ));
      AdSafetyConfig.recordFullscreenAdShown();
      expect(AdSafetyConfig.canShowAppOpenOnResume().canShow, isFalse);
      expect(AdSafetyConfig.canShowAppOpenOnResumePeek().canShow, isFalse);
    });

    test('daily cap', () async {
      await configure(AdSafetyParams.debug.copyWith(
        minTimeBetweenFullscreenAds: 0,
        maxFullscreenAdsPerDay: 1,
      ));
      AdSafetyConfig.recordFullscreenAdShown();
      expect(AdSafetyConfig.canShowAppOpenOnResume().canShow, isFalse);
      expect(AdSafetyConfig.canShowAppOpenOnResumePeek().canShow, isFalse);
    });

    test('dryRun still allows it, annotated with the original reason',
        () async {
      await configure(AdSafetyParams.debug.copyWith(
        minTimeBetweenFullscreenAds: 0,
        maxFullscreenAdsPerSession: 1,
        dryRun: true,
      ));
      AdSafetyConfig.recordFullscreenAdShown();
      final r = AdSafetyConfig.canShowAppOpenOnResume();
      expect(r.canShow, isTrue);
      expect(r.reason, contains('dryRun-bypass'));
    });

    test('no cap spent: resume is allowed', () async {
      await configure(AdSafetyParams.debug.copyWith(
        minTimeBetweenFullscreenAds: 0,
      ));
      expect(AdSafetyConfig.canShowAppOpenOnResume().canShow, isTrue);
    });
  });
}
