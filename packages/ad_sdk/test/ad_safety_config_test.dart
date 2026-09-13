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

    // Round-7 audit, MAJOR — this used to assert the opposite. `resetSession`
    // runs from the public, exported `resetForReinit()`, i.e. from every
    // `AdManager().destroy()`, so wiping the persisted counter here handed any
    // host a full reset of the progressive invalid-traffic cooldown for the
    // price of destroy() + initialize(). The in-memory count and pause still
    // clear (a plain process restart already does that much), but the
    // escalation counter is exactly what a restart keeps.
    test('does NOT clear the persisted suspicious count in AdPreferences',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(
        prefs,
        params: AdSafetyParams.debug.copyWith(
          suspiciousCtrThreshold: 0.5,
          // Round-39 audit fix: the CTR gate is now fullscreen-only, so
          // triggering it here needs recordFullscreenAdShown() calls, which
          // also update the throttle timestamp — zero it out so these tight
          // loops don't trip "wait N seconds" before the CTR check runs.
          minTimeBetweenFullscreenAds: 0,
        ),
      );
      AdSafetyConfig.resetForReinit();

      // Click cap is 999 in debug params — force a violation via CTR instead.
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordFullscreenAdShown();
        AdSafetyConfig.recordAdClick(fullscreen: true);
      }
      AdSafetyConfig.canShowFullscreenAd(); // triggers a CTR-anomaly pause
      expect(prefs.getSuspiciousCount(), greaterThan(0));

      final persisted = prefs.getSuspiciousCount();

      AdSafetyConfig.resetSession();
      expect(prefs.getSuspiciousCount(), persisted,
          reason: 'the escalation counter must survive a re-init');

      // And it comes straight back on the next initialize(), so the next
      // violation escalates instead of starting over at 30 minutes.
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount,
          persisted);
    });

    // Round-31 audit (MAJOR) — a blocked show attempt never adds an
    // impression, so the CTR ratio that tripped the FIRST pause could never
    // dilute on its own. The very next genuine show attempt after the pause
    // window elapsed re-evaluated the exact same stale ratio and immediately
    // re-triggered, escalating the pause (30m → 1h → 2h → ...) from a single
    // ambiguous burst at the start of a session, with no way to recover
    // short of an app restart clearing the in-memory counters.
    test(
        'a genuine show attempt right after the pause window elapses does '
        'NOT immediately re-trigger on the same stale CTR ratio', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await AdPreferences.getInstance();
      await AdSafetyConfig.init(
        p,
        params: AdSafetyParams.debug.copyWith(
          suspiciousCtrThreshold: 0.5,
          // Round-39 audit fix: the CTR gate is now fullscreen-only, so
          // triggering it here needs recordFullscreenAdShown() calls, which
          // also update the throttle timestamp — zero it out so these tight
          // loops don't trip "wait N seconds" before the CTR check runs.
          minTimeBetweenFullscreenAds: 0,
        ),
      );
      AdSafetyConfig.resetForReinit();

      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordFullscreenAdShown();
        AdSafetyConfig.recordAdClick(fullscreen: true);
      }
      AdSafetyConfig.canShowFullscreenAd(); // 100% CTR — triggers violation 1
      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 1,
          reason: 'sanity: the first violation fired');

      // Simulate the 30-minute pause window having elapsed. Nothing else
      // about the user's behaviour changed — no new impressions or clicks.
      AdSafetyConfig.debugExpireSuspiciousPause();
      final result = AdSafetyConfig.canShowFullscreenAd(); // very next attempt

      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount, 1,
          reason: 'a stale CTR ratio from before the pause must not '
              're-trigger a second, escalated violation on its own — the '
              'pause must act as a fresh-start probation');
      // Not re-triggering isn't enough on its own — the CTR gate must also
      // actually let this show attempt through, not just skip re-arming a
      // new pause while still reporting canShow:false. Otherwise no new
      // impression can ever happen and the stale ratio can never dilute —
      // a silent permanent deadlock, worse than the escalating-pause bug.
      expect(result.canShow, isTrue,
          reason: 'the gate must be skipped, not just non-escalating, or '
              'the ad can never show again to generate the fresh '
              'impressions the ratio needs to recover');
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
        params: AdSafetyParams.debug.copyWith(
          suspiciousCtrThreshold: 0.5,
          // Round-39 audit fix: the CTR gate is now fullscreen-only, so
          // triggering it here needs recordFullscreenAdShown() calls, which
          // also update the throttle timestamp — zero it out so these tight
          // loops don't trip "wait N seconds" before the CTR check runs.
          minTimeBetweenFullscreenAds: 0,
        ),
      );
      AdSafetyConfig.resetForReinit();

      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordFullscreenAdShown();
        AdSafetyConfig.recordAdClick(fullscreen: true);
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

    // Round-31 audit (MAJOR) — `hoursSince` was unclamped, so a system
    // clock rolled BACK past the last violation's timestamp (manual
    // change, NTP correction, a timezone/DST shift the wrong way) made it
    // negative, and `math.pow(0.5, negative)` is > 1 — the decay factor
    // AMPLIFIES the violation count instead of decaying it.
    test(
        'a clock rolled back past the last violation timestamp must not '
        'amplify the decayed violation count above the raw stored value',
        () {
      for (var i = 0; i < 4; i++) {
        AdSafetyConfig.recordAdClick();
      }
      final rawCount = AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount;
      expect(rawCount, greaterThan(0), reason: 'sanity: a violation fired');

      // "Now" appears to be 48h BEFORE the last violation — as if the
      // system clock were rolled back after the violation was recorded.
      AdSafetyConfig.debugSetLastViolationTimestamp(
          DateTime.now().millisecondsSinceEpoch + (48 * 60 * 60 * 1000));

      expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount,
          lessThanOrEqualTo(rawCount),
          reason: 'a rolled-back clock must never make the decayed count '
              'exceed the raw stored count — that is amplification, the '
              'opposite of decay');
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
        params: AdSafetyParams.debug.copyWith(
          suspiciousCtrThreshold: 0.5,
          // Round-39 audit fix: the CTR gate is now fullscreen-only, so
          // triggering it here needs recordFullscreenAdShown() calls, which
          // also update the throttle timestamp — zero it out so these tight
          // loops don't trip "wait N seconds" before the CTR check runs.
          minTimeBetweenFullscreenAds: 0,
        ),
      );
      AdSafetyConfig.resetForReinit();

      // Force a CTR anomaly: 100% CTR, well above the 0.5 threshold.
      for (var i = 0; i < 5; i++) {
        AdSafetyConfig.recordFullscreenAdShown();
        AdSafetyConfig.recordAdClick(fullscreen: true);
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

    // Round-29 audit (MAJOR) — tripping the rapid-resume cap used to
    // `.clear()` the whole rolling window, wiping its own evidence so the
    // very next resume passed with an empty window. A real rolling-window
    // cap must keep blocking every resume that lands inside the same 60s
    // window as the trip, not just the one that tripped it.
    test(
        'rapid-resume cap keeps blocking within the window instead of '
        'resetting to zero on trip', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug.copyWith(maxRapidResumesPerMinute: 2));
      AdSafetyConfig.resetForReinit();

      AdSafetyConfig.canShowAppOpenOnResume(); // consume cold start

      bool resumeOnce() {
        AdSafetyConfig.recordAppWentBackground();
        return AdSafetyConfig.canShowAppOpenOnResume().canShow;
      }

      expect(resumeOnce(), isTrue, reason: 'resume 1/2 — within cap');
      expect(resumeOnce(), isTrue, reason: 'resume 2/2 — within cap');
      expect(resumeOnce(), isFalse, reason: 'resume 3 — trips the cap');
      // The bug: this next call saw an empty (just-cleared) window and
      // passed. A real rolling window must still block it — the trip above
      // is still well inside the same 60s.
      expect(resumeOnce(), isFalse,
          reason: 'resume 4, still inside the same 60s window as the trip — '
              'must still be blocked, not reset to allowing again');
    });
  });

  // ─────────────────────────────────────────────────
  // canShowAppOpenOnResumePeek (T174)
  // ─────────────────────────────────────────────────
  group('canShowAppOpenOnResumePeek (T174)', () {
    test('repeated peeks never consume the one-shot cold-start flag — '
        'canShowAppOpenOnResume() (non-peek) still does', () async {
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();

      for (var i = 0; i < 5; i++) {
        final peek = AdSafetyConfig.canShowAppOpenOnResumePeek();
        expect(peek.canShow, isFalse);
        expect(peek.reason, contains('cold start'));
      }

      final real1 = AdSafetyConfig.canShowAppOpenOnResume();
      expect(real1.canShow, isFalse,
          reason:
              'cold start must still be pending — peek never consumed it, '
              'no matter how many times it was called');
      expect(real1.reason, contains('cold start'));

      // Cold start is consumed now (by real1). A later call must no longer
      // take the cold-start branch.
      AdSafetyConfig.recordAppWentBackground();
      final real2 = AdSafetyConfig.canShowAppOpenOnResume();
      expect(real2.reason, isNot(contains('cold start')));
    });

    test('repeated peeks never consume the pending-resume gate — a later '
        'call still sees a genuine (not spurious) resume', () async {
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdSafetyConfig.canShowAppOpenOnResume(); // consume cold start
      AdSafetyConfig.recordAppWentBackground(); // sets the pending-resume gate

      for (var i = 0; i < 5; i++) {
        final peek = AdSafetyConfig.canShowAppOpenOnResumePeek();
        expect(peek.reason, isNot(contains('spurious')),
            reason: 'T174 — if an earlier peek in this loop had consumed '
                'the pending-resume gate, THIS peek would misread the '
                'still-genuine backgrounding as a spurious resume');
      }

      final real = AdSafetyConfig.canShowAppOpenOnResume();
      expect(real.reason, isNot(contains('spurious')),
          reason: 'the gate must still be pending for the real call too — '
              'none of the peeks above may have consumed it');
    });

    test('repeated peeks never grow the rolling resume-timestamp window '
        'used for the rapid-resume cap', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug.copyWith(maxRapidResumesPerMinute: 2));
      AdSafetyConfig.resetForReinit();
      // Consumes cold start; no background recorded yet, so this falls
      // straight through to the resume-timestamp check and adds ONE real
      // entry to the window (1/2 of the cap).
      AdSafetyConfig.canShowAppOpenOnResume();

      for (var i = 0; i < 10; i++) {
        AdSafetyConfig.canShowAppOpenOnResumePeek();
      }

      // If any of the 10 peeks above had leaked into the real window, it
      // would already be over the cap of 2 by now.
      final real2 = AdSafetyConfig.canShowAppOpenOnResume();
      expect(real2.canShow, isTrue,
          reason: 'T174 — only one real resume happened before this (2nd '
              'of a cap of 2) — peek must not have silently grown the '
              'window past it');
    });

    test('reports the same canShow/reason as canShowAppOpenOnResume for a '
        'non-blocked state', () async {
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdSafetyConfig.canShowAppOpenOnResume(); // consume cold start
      AdSafetyConfig.recordAppWentBackground();

      final peek = AdSafetyConfig.canShowAppOpenOnResumePeek();
      final real = AdSafetyConfig.canShowAppOpenOnResume();
      expect(peek.canShow, isTrue);
      expect(real.canShow, peek.canShow);
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

    test(
        'T113: maxPerPlacementAdsPerDayById — const-declarable, keyed by '
        'AdPlacement.id string — enforces the same cap', () async {
      // The point of this field: this whole params object can be `const`,
      // which AdSafetyParams(maxPerPlacementAdsPerDay: {...}) cannot be
      // (AdPlacement overrides ==, so it can't be a const map key).
      const params =
          AdSafetyParams(maxPerPlacementAdsPerDayById: {'splash': 1});
      await AdSafetyConfig.init(prefs, params: params);
      AdSafetyConfig.resetForReinit();

      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
          isFalse);
      AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
          isTrue);
      expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.home),
          isFalse);
    });

    // T159 — both maps are "checked in addition to" each other per their
    // own doc comments, not one shadowing the other when both are set for
    // the same placement.
    group('both maps set for the same placement (T159)', () {
      test(
          'maxPerPlacementAdsPerDay stricter than maxPerPlacementAdsPerDayById '
          '→ the stricter (smaller) one wins', () async {
        await AdSafetyConfig.init(prefs,
            params: AdSafetyParams(
              maxPerPlacementAdsPerDay: {AdPlacement.splash: 1},
              maxPerPlacementAdsPerDayById: {'splash': 5},
            ));
        AdSafetyConfig.resetForReinit();

        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isFalse);
        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isTrue,
            reason: 'the stricter cap (1, from maxPerPlacementAdsPerDay) '
                'must apply even though maxPerPlacementAdsPerDayById (5) '
                'would have been checked first under the old `??` logic');
      });

      test(
          'maxPerPlacementAdsPerDayById stricter than maxPerPlacementAdsPerDay '
          '→ the stricter (smaller) one wins', () async {
        await AdSafetyConfig.init(prefs,
            params: AdSafetyParams(
              maxPerPlacementAdsPerDay: {AdPlacement.splash: 5},
              maxPerPlacementAdsPerDayById: {'splash': 1},
            ));
        AdSafetyConfig.resetForReinit();

        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isFalse);
        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isTrue,
            reason: 'the stricter cap (1, from maxPerPlacementAdsPerDayById) '
                'must apply even though maxPerPlacementAdsPerDay (5) is '
                'the map checked first');
      });

      test('equal caps in both maps behave exactly as either alone',
          () async {
        await AdSafetyConfig.init(prefs,
            params: AdSafetyParams(
              maxPerPlacementAdsPerDay: {AdPlacement.splash: 2},
              maxPerPlacementAdsPerDayById: {'splash': 2},
            ));
        AdSafetyConfig.resetForReinit();

        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isFalse);
        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isTrue);
      });

      test('only maxPerPlacementAdsPerDay set — unaffected (no breaking '
          'change to the single-map case)', () async {
        await AdSafetyConfig.init(prefs,
            params: AdSafetyParams(
                maxPerPlacementAdsPerDay: {AdPlacement.splash: 1}));
        AdSafetyConfig.resetForReinit();

        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isFalse);
        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isTrue);
      });

      test('only maxPerPlacementAdsPerDayById set — unaffected (no '
          'breaking change to the single-map case)', () async {
        const params =
            AdSafetyParams(maxPerPlacementAdsPerDayById: {'splash': 1});
        await AdSafetyConfig.init(prefs, params: params);
        AdSafetyConfig.resetForReinit();

        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isFalse);
        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isTrue);
      });

      test('capOverride still wins over BOTH maps, even when they disagree',
          () async {
        await AdSafetyConfig.init(prefs,
            params: AdSafetyParams(
              maxPerPlacementAdsPerDay: {AdPlacement.splash: 1},
              maxPerPlacementAdsPerDayById: {'splash': 9},
            ));
        AdSafetyConfig.resetForReinit();

        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        // Both configured caps disagree (1 vs 9) — a capOverride of 5 must
        // still take precedence over whichever of the two would otherwise
        // apply (the stricter, 1).
        expect(
            AdSafetyConfig.placementDailyCapReached(AdPlacement.splash,
                capOverride: 5),
            isFalse,
            reason: 'capOverride (5) must win over both configured maps, '
                'not just the stricter of the two');
      });
    });

    // T140 — PlacementRegistry's frequencyCapOverride feeds in here.
    group('capOverride parameter (T140)', () {
      test('capOverride applies even when this placement has NO configured '
          'cap otherwise', () async {
        await AdSafetyConfig.init(prefs); // no maxPerPlacementAdsPerDay at all
        AdSafetyConfig.resetForReinit();

        expect(
            AdSafetyConfig.placementDailyCapReached(AdPlacement.splash,
                capOverride: 1),
            isFalse);
        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(
            AdSafetyConfig.placementDailyCapReached(AdPlacement.splash,
                capOverride: 1),
            isTrue,
            reason: 'capOverride must be able to introduce a cap where '
                'AdSafetyParams configured none at all');
      });

      test('capOverride takes precedence over the configured '
          'maxPerPlacementAdsPerDay value for this call', () async {
        await AdSafetyConfig.init(prefs,
            params:
                AdSafetyParams(maxPerPlacementAdsPerDay: {
              AdPlacement.splash: 5
            }));
        AdSafetyConfig.resetForReinit();

        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        // Configured cap (5) is not reached yet — but a stricter override
        // (1) for THIS call must still block.
        expect(
            AdSafetyConfig.placementDailyCapReached(AdPlacement.splash,
                capOverride: 1),
            isTrue,
            reason: 'capOverride must win over the configured 5/day cap');
        // The SAME placement, with no override passed, still uses the
        // configured cap — proving the override is call-scoped, not a
        // mutation of the underlying configured value.
        expect(
            AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isFalse,
            reason: 'omitting capOverride must fall back to the '
                'configured cap unchanged — 1 shown is still below 5');
      });

      test('capOverride: null (the default) preserves the exact pre-T140 '
          'behavior', () async {
        await AdSafetyConfig.init(prefs,
            params:
                AdSafetyParams(maxPerPlacementAdsPerDay: {
              AdPlacement.splash: 1
            }));
        AdSafetyConfig.resetForReinit();

        AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);
        expect(
            AdSafetyConfig.placementDailyCapReached(AdPlacement.splash),
            isTrue);
      });
    });
  });

  // ─────────────────────────────────────────────────
  // T126 — creative fatigue guard
  // ─────────────────────────────────────────────────
  group('T126: creative fatigue guard', () {
    test('same network repeated up to the threshold → not fatigued yet, '
        'one more → fatigued', () async {
      const params = AdSafetyParams(maxSameNetworkShowsPerWindow: 3);
      await AdSafetyConfig.init(prefs, params: params);
      AdSafetyConfig.resetForReinit();

      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.interstitial),
          isFalse);
      AdSafetyConfig.recordNetworkShown(AdSlotType.interstitial, 'vungle');
      AdSafetyConfig.recordNetworkShown(AdSlotType.interstitial, 'vungle');
      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.interstitial),
          isFalse,
          reason: '2 shows < threshold of 3');
      AdSafetyConfig.recordNetworkShown(AdSlotType.interstitial, 'vungle');
      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.interstitial),
          isTrue,
          reason: '3rd show hits the threshold');
    });

    test('missing network metadata (null) fails open — never recorded, '
        'never cools anything down', () async {
      const params = AdSafetyParams(maxSameNetworkShowsPerWindow: 1);
      await AdSafetyConfig.init(prefs, params: params);
      AdSafetyConfig.resetForReinit();

      for (var i = 0; i < 10; i++) {
        AdSafetyConfig.recordNetworkShown(AdSlotType.rewarded, null);
      }
      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.rewarded), isFalse,
          reason:
              'no network metadata ever reported — nothing to cool down, '
              'and a real ad must never be blocked for lack of data');
    });

    test('fatigue on one AdSlotType does not bleed into another', () async {
      const params = AdSafetyParams(maxSameNetworkShowsPerWindow: 1);
      await AdSafetyConfig.init(prefs, params: params);
      AdSafetyConfig.resetForReinit();

      AdSafetyConfig.recordNetworkShown(AdSlotType.rewarded, 'ironsource');
      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.rewarded), isTrue);
      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.interstitial),
          isFalse);
    });

    test('resetSession() clears fatigue history', () async {
      const params = AdSafetyParams(maxSameNetworkShowsPerWindow: 1);
      await AdSafetyConfig.init(prefs, params: params);
      AdSafetyConfig.resetForReinit();

      AdSafetyConfig.recordNetworkShown(AdSlotType.appOpen, 'meta');
      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.appOpen), isTrue);
      AdSafetyConfig.resetSession();
      expect(AdSafetyConfig.isNetworkFatigued(AdSlotType.appOpen), isFalse);
    });
  });

  // ─────────────────────────────────────────────────
  // T137 — disabledFormats kill switch
  // ─────────────────────────────────────────────────
  group('disabledFormats kill switch (T137)', () {
    test('a disabled format is blocked when forType is passed', () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(disabledFormats: {'rewarded'}));

      final result =
          AdSafetyConfig.canShowFullscreenAd(forType: AdSlotType.rewarded);

      expect(result.canShow, isFalse);
      expect(result.reason, 'formatDisabledRemotely');
    });

    test('a format NOT in disabledFormats is unaffected', () async {
      // AdSafetyParams.debug — every OTHER gate (session-too-young,
      // cold-start, throttle) loosened to 0/999 so a `true` result here can
      // only be about disabledFormats, not some unrelated gate.
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug.copyWith(disabledFormats: {'rewarded'}));

      final result = AdSafetyConfig.canShowFullscreenAd(
          forType: AdSlotType.interstitial);

      expect(result.canShow, isTrue);
    });

    test('omitting forType never blocks — every caller outside this SDK '
        'that never passes it keeps its exact pre-T137 behavior', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug.copyWith(disabledFormats: {'rewarded'}));

      final result = AdSafetyConfig.canShowFullscreenAd();

      expect(result.canShow, isTrue,
          reason: 'disabledFormats can only ever gate a caller that '
              'explicitly opts in via forType');
    });

    test('null disabledFormats (the default) blocks nothing', () async {
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);

      final result =
          AdSafetyConfig.canShowFullscreenAd(forType: AdSlotType.rewarded);

      expect(result.canShow, isTrue);
    });

    test('canShowFullscreenAdPeek() also honors forType, without recording '
        'a violation', () async {
      await AdSafetyConfig.init(prefs,
          params: const AdSafetyParams(disabledFormats: {'appOpen'}));

      final result = AdSafetyConfig.canShowFullscreenAdPeek(
          forType: AdSlotType.appOpen);

      expect(result.canShow, isFalse);
      expect(result.reason, 'formatDisabledRemotely');
    });

    test('copyWith(disabledFormats: ...) replaces the set; omitting it '
        'preserves the old one', () {
      const original = AdSafetyParams(disabledFormats: {'rewarded'});
      final unchanged = original.copyWith(maxFullscreenAdsPerDay: 10);
      final replaced =
          original.copyWith(disabledFormats: {'interstitial'});

      expect(unchanged.disabledFormats, {'rewarded'});
      expect(replaced.disabledFormats, {'interstitial'});
    });
  });

  // ─────────────────────────────────────────────────
  // T181 — minIntervalOverrideMs (per-placement throttle override)
  // ─────────────────────────────────────────────────
  group('minIntervalOverrideMs (T181)', () {
    test('a TIGHTER override blocks even though the app-wide throttle '
        'alone would allow it', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 0));
      AdSafetyConfig.recordFullscreenAdShown();

      final result =
          AdSafetyConfig.canShowFullscreenAd(minIntervalOverrideMs: 999999999);

      expect(result.canShow, isFalse);
      expect(result.reason, contains('Throttle'));
    });

    test('a LOOSER override allows even though the app-wide throttle alone '
        'would still be blocking', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 999999999));
      AdSafetyConfig.recordFullscreenAdShown();

      final result =
          AdSafetyConfig.canShowFullscreenAd(minIntervalOverrideMs: 0);

      expect(result.canShow, isTrue);
    });

    test('omitting minIntervalOverrideMs (the default) uses the app-wide '
        'value unchanged — exact pre-T181 behavior', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 999999999));
      AdSafetyConfig.recordFullscreenAdShown();

      final result = AdSafetyConfig.canShowFullscreenAd();

      expect(result.canShow, isFalse,
          reason: 'no override passed — the app-wide throttle alone must '
              'still apply, same as before T181');
    });

    test('canShowFullscreenAdPeek() also honors minIntervalOverrideMs, '
        'without recording a violation', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 0));
      AdSafetyConfig.recordFullscreenAdShown();

      final result =
          AdSafetyConfig.canShowFullscreenAdPeek(minIntervalOverrideMs: 999999999);

      expect(result.canShow, isFalse);
      expect(result.reason, contains('Throttle'));
    });

    // codex round-6 fix — a negative override used to make
    // `elapsed < minInterval` unconditionally false (elapsed is never
    // negative), silently disabling the throttle entirely — even though
    // the app-wide interval itself is a perfectly valid, deliberately
    // configured value. `0` is the real, intentional bypass value; a
    // negative value is not a deliberate choice of anything, so it is
    // REJECTED outright and falls back to the app-wide value, exactly as
    // if no override had been passed.
    test('a NEGATIVE override is rejected — it falls back to the app-wide '
        'value instead of disabling the throttle', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 999999999));
      AdSafetyConfig.recordFullscreenAdShown();

      final result =
          AdSafetyConfig.canShowFullscreenAdPeek(minIntervalOverrideMs: -1);

      expect(result.canShow, isFalse,
          reason: 'a negative override must not disable the throttle — it '
              'must fall back to the app-wide value, which is still '
              'blocking here');
      expect(result.reason, contains('Throttle'));
    });

    test('canShowAppOpenOnResume() also rejects a negative override, '
        'falling back to the app-wide value', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 999999999));
      // `minIntervalOverrideMs: 0` here bypasses the throttle for JUST this
      // consume call — a leftover _lastFullscreenAdTime from an earlier
      // test (never reset by resetSession()) combined with this test's
      // deliberately huge app-wide value would otherwise block the
      // throttle check BEFORE the cold-start check even runs, leaving
      // cold start un-consumed for the real assertion below.
      AdSafetyConfig.canShowAppOpenOnResume(minIntervalOverrideMs: 0);
      AdSafetyConfig.recordFullscreenAdShown();

      final result = AdSafetyConfig.canShowAppOpenOnResumePeek(
          minIntervalOverrideMs: -999999999);

      expect(result.canShow, isFalse);
    });

    // codex round-1 fix — canShowAppOpenOnResume/Peek used to have no
    // override at all: the resume-triggered App Open flow's own preflight
    // check only ever saw the app-wide minTimeBetweenFullscreenAds.
    test('canShowAppOpenOnResume() honors minIntervalOverrideMs too', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 0));
      AdSafetyConfig.canShowAppOpenOnResume(); // consume cold start
      AdSafetyConfig.recordFullscreenAdShown();

      final result = AdSafetyConfig.canShowAppOpenOnResume(
          minIntervalOverrideMs: 999999999);

      expect(result.canShow, isFalse);
      expect(result.reason, contains('fullscreen throttle'));
    });

    test('canShowAppOpenOnResumePeek() honors minIntervalOverrideMs too',
        () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 999999999));
      // minIntervalOverrideMs: 0 bypasses the throttle for JUST this
      // consume call — see the matching comment on the negative-override
      // test above for why this is needed with such a large app-wide value.
      AdSafetyConfig.canShowAppOpenOnResume(minIntervalOverrideMs: 0);
      AdSafetyConfig.recordFullscreenAdShown();

      final result = AdSafetyConfig.canShowAppOpenOnResumePeek(
          minIntervalOverrideMs: 0);

      expect(result.canShow, isTrue,
          reason: 'a looser override must let this through even though the '
              'app-wide throttle alone would still be blocking');
    });

    test('omitting minIntervalOverrideMs on canShowAppOpenOnResume uses the '
        'app-wide value unchanged — exact pre-T181 behavior', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 999999999));
      AdSafetyConfig.canShowAppOpenOnResume(minIntervalOverrideMs: 0);
      AdSafetyConfig.recordFullscreenAdShown();

      final result = AdSafetyConfig.canShowAppOpenOnResume();

      expect(result.canShow, isFalse);
    });
  });
}
