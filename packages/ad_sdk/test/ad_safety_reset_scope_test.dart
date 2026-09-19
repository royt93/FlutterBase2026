// M2 (round-6 audit) — `resetSession()` clears the session counters AND the
// persisted invalid-traffic history, and it was reachable from any consuming
// app through the exported `AdSafetyConfig`. One call defeated the whole
// progressive-cooldown design (30 min → 24 h), and the example shipped a
// button wired straight to it, labelled "Reset session counters" — which is
// what a host would reasonably expect it to do.
//
// The previous round (T24) deliberately moved the violation clearing INTO
// resetSession, on the grounds that a "full" reset leaving old violations
// alive was itself the bug. That reasoning is kept: the internal reset still
// clears everything consistently. What changes is what a HOST can reach.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/core/ad_safety_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
  });

  /// Trips the click-spam detector through the real production path.
  void tripInvalidTrafficPause() {
    for (var i = 0; i <= AdSafetyParams.debug.maxClicksPerMinute; i++) {
      AdSafetyConfig.recordAdClick();
    }
  }

  test('the host-facing reset does NOT clear the invalid-traffic pause', () {
    tripInvalidTrafficPause();
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
        reason: 'sanity check: the pause must be active to begin with');

    AdSafetyConfig.resetSessionCounters();

    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
        reason: 'a host clearing its session counters must not hand itself an '
            'amnesty on click-fraud history — that guard protects the '
            "publisher's AdMob account, not the user's pacing");
  });

  test('the host-facing reset DOES clear the session ad count', () {
    AdSafetyConfig.recordFullscreenAdShown();
    expect(AdSafetyConfig.getSessionAdCount(), greaterThan(0));

    AdSafetyConfig.resetSessionCounters();

    expect(AdSafetyConfig.getSessionAdCount(), 0,
        reason: 'this is what the name promises and what the example button '
            'is labelled — it has to actually do it');
  });

  // Round 49 audit fix (MAJOR) — `resetSessionCounters()`'s own doc comment
  // and log line already promised "fraud history preserved", but it was
  // zeroing `_fullscreenImpressions`/`_fullscreenClicks` too, which is
  // exactly the state the CTR-anomaly gate below needs 5 cumulative
  // impressions to ever evaluate. A host calling this reset before 5
  // impressions land between calls could permanently prevent the gate from
  // firing, no matter how bad the real CTR was.
  test(
      'resetSessionCounters does NOT reset the CTR-anomaly fullscreen '
      'impression/click counters', () {
    // 4 fullscreen impressions + fullscreen clicks pre-reset — not yet
    // enough for the gate to evaluate (it requires >= 5 cumulative
    // impressions before it looks at the ratio at all).
    for (var i = 0; i < 4; i++) {
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordAdClick(fullscreen: true);
    }

    AdSafetyConfig.resetSessionCounters();

    // One more impression brings the cumulative fullscreen count to 5. If
    // the reset above had wiped `_fullscreenImpressions`, the gate would
    // only see this 1 impression and could never evaluate the CTR. Two
    // clicks on it makes 6 clicks / 5 impressions = 120%, strictly over
    // the debug threshold (100% — `ctr > threshold`, not `>=`).
    AdSafetyConfig.recordFullscreenAdShown();
    AdSafetyConfig.recordAdClick(fullscreen: true);
    AdSafetyConfig.recordAdClick(fullscreen: true);

    // minIntervalOverrideMs: 0 is the documented, intentional "no throttle
    // for this placement" bypass — isolates the CTR-anomaly gate from the
    // unrelated (and, in a real app, entirely legitimate) fullscreen
    // throttle so this test only proves what it claims to.
    final result =
        AdSafetyConfig.canShowFullscreenAd(minIntervalOverrideMs: 0);

    expect(result.canShow, isFalse);
    expect(result.reason, contains('CTR too high'),
        reason: 'CTR is 6 clicks / 5 impressions = 120%, over the debug '
            'threshold (100%) — resetSessionCounters must not let a host '
            'dodge this gate by resetting the impression count back to '
            'near zero');
  });

  test('the internal full reset still clears everything (T24 behaviour kept)',
      () {
    tripInvalidTrafficPause();
    AdSafetyConfig.recordFullscreenAdShown();

    AdSafetyConfig.resetSession();

    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isFalse,
        reason: 'T24: a full reset reporting suspended=true with 0 violations '
            'was the bug that fix addressed — do not regress it');
    expect(AdSafetyConfig.getSessionAdCount(), 0);
  });

  // Round-7 audit, MAJOR — M2 above closed the `resetSessionCounters()` door
  // and left a wider one open: `resetForReinit()` is public, exported, and
  // `AdManager().destroy()` calls it, so destroy() + initialize() (a provider
  // switch, a logout, a settings screen that re-inits) used to zero the
  // PERSISTED escalation counter too. The in-memory pause clearing is fine —
  // a plain process restart already does that, the pause is not persisted —
  // but the counter is precisely what a restart keeps, and it is what makes
  // the next violation escalate 30 min → 1 h → … → 24 h.
  test('a re-init does not forgive the invalid-traffic escalation counter',
      () async {
    final prefs = await AdPreferences.getInstance();
    tripInvalidTrafficPause();
    final escalation = prefs.getSuspiciousCount();
    expect(escalation, greaterThan(0), reason: 'sanity: a violation landed');

    AdSafetyConfig.resetForReinit(); // what AdManager().destroy() runs

    expect(prefs.getSuspiciousCount(), escalation);
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount,
        escalation,
        reason: 'the next pause must escalate, not restart at 30 minutes');
  });
}
