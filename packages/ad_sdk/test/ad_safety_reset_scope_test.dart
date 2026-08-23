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
}
