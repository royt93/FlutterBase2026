// On-device integration test for round-23 MINOR V5 — a whitelisted test device
// must get its VIP back after the clamped window runs out.
//
// The finding: `AdConfig.vipDeviceGaids` grants a long window that
// `AdConfig.maxVipStackDuration` clamps to ~90 days, and then set a one-way
// "already applied" flag. When the clamped window ran out, the whitelisted
// device — an internal test phone, by construction — silently went back to
// seeing ads, with no way to re-grant short of clearing app data.
//
// Why this file exists on top of the unit test
// (`packages/ad_sdk/test/r23_gaid_whitelist_regrant_test.dart`): the unit test
// feeds a hand-written GAID string. The match is case-insensitive against a
// value that on a real device comes out of the `advertising_id` plugin, in
// whatever case the platform chose, and against `SharedPreferences` written by
// the real platform channel. A whitelist that matches a literal in a test and
// not the string the plugin actually returns would help nobody.
//
// Run with:
//   flutter test integration_test/r23_gaid_whitelist_regrant_test.dart -d <device-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised && AdManager().vip != null) return;
  }
  fail('SDK must finish initialising on device');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'the real device GAID matches the whitelist, and the grant comes back '
      'after the clamped window has run out', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final realGaid = AdManager().currentDeviceGaid;
    if (defaultTargetPlatform != TargetPlatform.android || realGaid.isEmpty) {
      // The GAID only exists on Android, and only once the plugin has
      // resolved it. On iOS the counterpart is the IDFA, which is empty
      // without an ATT grant — there is nothing to match against, and
      // asserting on an empty string would match every device.
      //
      // Round-25 QC (reviewer A): a bare `return` here reported a green test
      // that had asserted nothing. Say so out loud instead — a skip that reads
      // as a pass is worse than no test.
      markTestSkipped('no real GAID on this platform — nothing to match');
      return;
    }

    final vip = AdManager().vip!;
    final prefs = await AdPreferences.getInstance();

    // Deliberately upper-cased. The plugin's own casing is not guaranteed,
    // and a host pasting a GAID out of a dashboard will not preserve it.
    final config = AdConfig(
      provider: AdProvider.admob,
      admob: const AdMobConfig(
          bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
      vipDeviceGaids: [realGaid.toUpperCase()],
    );

    await vip.revokeAll();
    await _settle(tester);

    // First init on a whitelisted device.
    await AdManager().debugApplyConfigVipGaidWhitelist(
      config,
      vip,
      prefs,
      deviceGaid: realGaid,
    );
    await _settle(tester);

    expect(vip.isActive, isTrue,
        reason: 'the whitelist must match the GAID the real plugin returned, '
            'regardless of case');
    expect(prefs.isAddVIPMemberFirstInitSuccess(), isTrue,
        reason: 'sanity — the one-way flag is set, which is what used to make '
            'this a one-shot grant');

    // ~90 days later: the clamped window has run out. Simulate exactly that
    // and nothing else — the flag stays set, as it would on a real device.
    await vip.revokeAll();
    await _settle(tester);
    expect(vip.isActive, isFalse, reason: 'sanity — the window is over');

    await AdManager().debugApplyConfigVipGaidWhitelist(
      config,
      vip,
      prefs,
      deviceGaid: realGaid,
    );
    await _settle(tester);

    expect(vip.isActive, isTrue,
        reason: 'THE finding — a whitelisted test device that lost its window '
            'must be able to get it back without clearing app data');

    await vip.revokeAll();
    await _settle(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('CONTROL — a GAID that is not on the whitelist gets nothing',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final realGaid = AdManager().currentDeviceGaid;
    if (defaultTargetPlatform != TargetPlatform.android || realGaid.isEmpty) {
      markTestSkipped('no real GAID on this platform — nothing to match');
      return;
    }

    final vip = AdManager().vip!;
    final prefs = await AdPreferences.getInstance();

    await vip.revokeAll();
    await _settle(tester);

    await AdManager().debugApplyConfigVipGaidWhitelist(
      const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
            bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
        vipDeviceGaids: ['00000000-0000-0000-0000-000000000000'],
      ),
      vip,
      prefs,
      deviceGaid: realGaid,
    );
    await _settle(tester);

    expect(vip.isActive, isFalse,
        reason: 're-granting on every launch regardless of the whitelist '
            'would hand free VIP to every user of the app');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
