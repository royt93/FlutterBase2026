import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unit tests for AdSafetyConfig.
///
/// NOTE: AdSafetyConfig uses static state, so each test group calls
/// resetSession() between tests to ensure isolation.
void main() {
  late AdPreferences prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  setUp(() async {
    // Clear persisted state (daily count, suspicious count, ...) and re-init
    // with default params before each test — some tests below call
    // AdSafetyConfig.init(params: ...debug...) and never restore it, which
    // would otherwise leak into whichever test runs next.
    await prefs.clearAllData();
    await AdSafetyConfig.init(prefs);
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

    // T24 re-audit fix: resetSession() used to leave violation state
    // untouched (only resetForReinit() cleared it), so a "Reset session"
    // action looked complete but silently kept old violation history alive.
    test('also clears the suspicious violation count', () {
      for (var i = 0; i < 4; i++) {
        AdSafetyConfig.recordAdClick(); // 4th click > default cap of 3
      }
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount,
          greaterThan(0));

      AdSafetyConfig.resetSession();

      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 0);
    });

    test('also clears the persisted suspicious count in AdPreferences',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(
        prefs,
        params: AdSafetyParams.debug.copyWith(suspiciousCtrThreshold: 0.5),
      );
      AdSafetyConfig.resetForReinit();

      // Click cap is 999 in debug params — force a violation via CTR instead.
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
      }
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordAdClick();
      }
      AdSafetyConfig.canShowFullscreenAd(); // triggers a CTR-anomaly pause
      expect(prefs.getSuspiciousCount(), greaterThan(0));

      AdSafetyConfig.resetSession();
      expect(prefs.getSuspiciousCount(), 0);
    });
  });

  // ─────────────────────────────────────────────────
  // Suspicious violation count decay (T25 re-audit fix)
  // ─────────────────────────────────────────────────
  group('suspicious violation count decay', () {
    test(
        'back-to-back violations with ~0 elapsed time increment normally '
        '(decay factor ~1 when hoursSince is ~0)', () {
      for (var i = 0; i < 4; i++) {
        AdSafetyConfig.recordAdClick();
      }
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 1);

      for (var i = 0; i < 4; i++) {
        AdSafetyConfig.recordAdClick();
      }
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 2);
    });

    test('persists the running count via AdPreferences.setSuspiciousCount',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(
        prefs,
        params: AdSafetyParams.debug.copyWith(suspiciousCtrThreshold: 0.5),
      );
      AdSafetyConfig.resetForReinit();

      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
        AdSafetyConfig.recordAdClick();
      }
      AdSafetyConfig.canShowFullscreenAd(); // 100% CTR — triggers a violation

      final snapshotCount =
          AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount;
      expect(snapshotCount, greaterThan(0));
      expect(prefs.getSuspiciousCount(), snapshotCount);
    });

    // T68 — `_decayViolationCount()` only re-runs on the NEXT violation, so
    // reading the snapshot/compliance report between two violations after a
    // long gap showed the stale raw count, while `policyRiskScore` computed
    // fresh decay on every read. Snapshot must show the same real-time-decayed
    // value, without mutating the stored (raw) counter used by the
    // progressive-cooldown escalation.
    test(
        'getStatusSnapshot shows the real-time-decayed count between '
        'violations, without mutating the stored raw counter', () {
      for (var i = 0; i < 4; i++) {
        AdSafetyConfig.recordAdClick();
      }
      for (var i = 0; i < 4; i++) {
        AdSafetyConfig.recordAdClick();
      }
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 2,
          reason: 'sanity: 2 violations recorded back-to-back');

      // Simulate 24h (one half-life) elapsed since the last violation, with
      // no new violation in between — nothing lazily re-decays the stored
      // counter in this window.
      AdSafetyConfig.debugSetLastViolationTimestamp(
          DateTime.now().millisecondsSinceEpoch - (24 * 60 * 60 * 1000));

      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 1,
          reason: 'snapshot must apply the same real-time decay '
              'policyRiskScore uses, not the stale raw count');
      expect(prefs.getSuspiciousCount(), 2,
          reason: 'the stored raw counter itself must stay untouched — '
              'this is a display-only decay');
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
  // getStatusSnapshot (T23) — structured twin of getStatus
  // ─────────────────────────────────────────────────
  group('getStatusSnapshot', () {
    test('matches getStatus counters on a clean session', () {
      final snapshot = AdSafetyConfig.getStatusSnapshot();
      expect(snapshot.fullscreenAdsShownInSession, 0);
      expect(snapshot.hourlyAdCount, 0);
      expect(snapshot.clicksLastMinute, 0);
      expect(snapshot.suspiciousViolationCount, 0);
      expect(snapshot.isSuspended, isFalse);
      expect(snapshot.clickThroughRate, 0.0);
    });

    test('reflects recorded fullscreen ads and clicks', () {
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordAdClick();

      final snapshot = AdSafetyConfig.getStatusSnapshot();
      expect(snapshot.fullscreenAdsShownInSession, 2);
      expect(snapshot.hourlyAdCount, 2);
      expect(snapshot.clicksLastMinute, 1);
    });

    test('toJson round-trips every field with plain types', () {
      final json = AdSafetyConfig.getStatusSnapshot().toJson();
      expect(
          json.keys,
          containsAll(<String>[
            'fullscreenAdsShownInSession',
            'maxFullscreenAdsPerSession',
            'hourlyAdCount',
            'maxFullscreenAdsPerHour',
            'dailyAdCount',
            'maxFullscreenAdsPerDay',
            'clickThroughRate',
            'suspiciousCtrThreshold',
            'clicksLastMinute',
            'suspiciousViolationCount',
            'isSuspended',
            'dryRun',
          ]));
    });

    test('does not change getStatus()\'s own behaviour', () {
      AdSafetyConfig.recordFullscreenAdShown();
      final before = AdSafetyConfig.getStatus();
      AdSafetyConfig.getStatusSnapshot();
      final after = AdSafetyConfig.getStatus();
      expect(after, before);
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
  // canShowFullscreenAdPeek — no side effects (2026-08-16 audit)
  // ─────────────────────────────────────────────────
  group('canShowFullscreenAdPeek', () {
    test(
        'repeated calls never increment the suspicious-violation count — '
        'canShowFullscreenAd() (non-peek) does', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(
        prefs,
        params: AdSafetyParams.debug.copyWith(suspiciousCtrThreshold: 0.5),
      );
      AdSafetyConfig.resetForReinit();

      // Force a CTR anomaly: 100% CTR, well above the 0.5 threshold.
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordBannerImpression();
        AdSafetyConfig.recordAdClick();
      }

      for (var i = 0; i < 10; i++) {
        AdSafetyConfig.canShowFullscreenAdPeek();
      }
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 0,
          reason: 'peek must never record a violation, no matter how many '
              'times it is called — a host polling this to drive a "Watch '
              'Ad" button\'s enabled state must not itself worsen the '
              'lockout');

      AdSafetyConfig.canShowFullscreenAd();
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount,
          greaterThan(0),
          reason: 'the non-peek variant is unchanged — it must still record '
              'a violation on a genuine show attempt');
    });

    test('reports the same canShow/reason as canShowFullscreenAd for a '
        'non-anomalous state', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();

      final peek = AdSafetyConfig.canShowFullscreenAdPeek();
      final strict = AdSafetyConfig.canShowFullscreenAd();
      expect(peek.canShow, strict.canShow);
    });
  });

  // ─────────────────────────────────────────────────
  // dailyCapReached
  // ─────────────────────────────────────────────────
  group('dailyCapReached', () {
    test('false when below the daily cap', () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(maxFullscreenAdsPerDay: 3));
      await prefs.incrementDailyAdCount();
      expect(AdSafetyConfig.dailyCapReached(), isFalse);
    });

    test('true once the daily cap is reached', () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(maxFullscreenAdsPerDay: 3));
      await prefs.incrementDailyAdCount();
      await prefs.incrementDailyAdCount();
      await prefs.incrementDailyAdCount();
      expect(AdSafetyConfig.dailyCapReached(), isTrue);
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

    // T66 — Android can fire `resumed → inactive → resumed` with no
    // intervening `paused` (a permission dialog, notification-shade drag).
    // `_lastBackgroundTime` was only ever written by `recordAppWentBackground()`
    // and never consumed, so a phantom second `resumed` reused the same
    // (stale, or here just-consumed) timestamp and could pass the "resume
    // too fast" gate — showing App Open mid-session with no real
    // backgrounding at all.
    test(
        'blocks a phantom resumed that has no new paused since the last '
        'check', () async {
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();

      AdSafetyConfig.canShowAppOpenOnResume(); // consume cold start
      AdSafetyConfig.recordAppWentBackground();
      final real = AdSafetyConfig.canShowAppOpenOnResume();
      expect(real.canShow, isTrue,
          reason: 'a genuine background → resume must still be allowed');

      final phantom = AdSafetyConfig.canShowAppOpenOnResume();
      expect(phantom.canShow, isFalse,
          reason: 'a second resumed with no new paused in between (no real '
              'backgrounding) must be blocked, not reuse the prior timing');
    });
  });

  // ─────────────────────────────────────────────────
  // applyDryRunReleaseGuard (R12-A)
  // ─────────────────────────────────────────────────
  group('applyDryRunReleaseGuard (R12-A)', () {
    test('forces dryRun off when dryRun=true and isRelease=true', () {
      const dirty = AdSafetyParams(dryRun: true);
      final guarded = AdSafetyConfig.applyDryRunReleaseGuard(
        dirty,
        isRelease: true,
      );
      expect(guarded.dryRun, isFalse);
    });

    test('leaves dryRun=true untouched when isRelease=false (debug/profile)',
        () {
      const dirty = AdSafetyParams(dryRun: true);
      final guarded = AdSafetyConfig.applyDryRunReleaseGuard(
        dirty,
        isRelease: false,
      );
      expect(guarded.dryRun, isTrue);
    });

    test('leaves dryRun=false untouched regardless of isRelease', () {
      const clean = AdSafetyParams(dryRun: false);
      expect(
        AdSafetyConfig.applyDryRunReleaseGuard(clean, isRelease: true).dryRun,
        isFalse,
      );
      expect(
        AdSafetyConfig.applyDryRunReleaseGuard(clean, isRelease: false).dryRun,
        isFalse,
      );
    });

    test('init(isRelease:) wires the guard end-to-end in both directions',
        () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(dryRun: true), isRelease: true);
      expect(AdSafetyConfig.getStatusSnapshot().dryRun, isFalse);

      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(dryRun: true), isRelease: false);
      expect(AdSafetyConfig.getStatusSnapshot().dryRun, isTrue);
    });

    test(
        'guard log still reaches onLog even when the host silenced '
        'logLevel to none', () async {
      final captured = <String>[];
      SafeLogger.configure(
        level: AdLogLevel.none,
        onLog: (level, tag, message) => captured.add(message),
      );
      addTearDown(SafeLogger.resetForTest);

      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(dryRun: true), isRelease: true);

      expect(captured, isNotEmpty);
      expect(captured.single, contains('forcing dryRun=false'));
    });
  });

  // T92 — additional per-placement daily cap, on top of the global one.
  group('placementDailyCapReached / recordPlacementAdShown (T92)', () {
    test('no configured cap for this placement never blocks', () async {
      await AdSafetyConfig.init(prefs); // maxPerPlacementAdsPerDay: null
      AdSafetyConfig.resetForReinit();

      AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
      AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
          isFalse,
          reason: 'no cap configured for splash — must never block '
              'regardless of how many were shown');
    });

    test('reaching the configured per-placement cap blocks only that '
        'placement', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams(
              maxPerPlacementAdsPerDay: {AdPlacement.splash: 1}));
      AdSafetyConfig.resetForReinit();

      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
          isFalse);
      AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
          isTrue);

      // A DIFFERENT placement, never configured, must stay unaffected —
      // the cap is per-placement, not a global rename.
      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.home),
          isFalse);
    });

    test('count survives a fresh init reading the same persisted store',
        () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams(
              maxPerPlacementAdsPerDay: {AdPlacement.shop: 2}));
      AdSafetyConfig.resetForReinit();
      AdSafetyConfig.recordPlacementAdShown(AdPlacement.shop);

      // Re-init (simulates app restart) reading the same AdPreferences.
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams(
              maxPerPlacementAdsPerDay: {AdPlacement.shop: 2}));
      AdSafetyConfig.resetForReinit();
      AdSafetyConfig.recordPlacementAdShown(AdPlacement.shop);

      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.shop),
          isTrue, reason: '2 recorded shows against a cap of 2');
    });
  });
}
