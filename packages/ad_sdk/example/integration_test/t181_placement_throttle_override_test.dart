// T181 on-device integration test — a real canShowInterstitial(placement:)
// call, on a real device with a real AdMob interstitial actually loaded,
// honors PlacementSpec.minIntervalOverrideMs — end to end through a real
// initialize(), not just the debugConfig-seeded unit tests in
// test/ad_manager_core_test.dart and test/ad_safety_config_test.dart.
//
// Run with:
//   flutter test integration_test/t181_placement_throttle_override_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _loosePlacement = AdPlacement.custom('t181_loose');

AdConfig _config() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      // A deliberately huge app-wide throttle — the point of this test is
      // to prove t181_loose's registered override lets it through anyway.
      // dryRun is deliberately OFF (unlike some sibling placement tests):
      // dryRun bypasses a blocked result to canShow=true, which would
      // hide the exact "still throttled" signal this test needs to
      // observe for the default placement. minSessionDurationBeforeAd is
      // zeroed so the unrelated "session too young" gate (production
      // default: 10s) doesn't block BOTH placements before the throttle
      // check this test cares about ever runs.
      safety: AdSafetyParams(
          minTimeBetweenFullscreenAds: 999999999,
          minSessionDurationBeforeAd: 0),
      // Debug builds grant first-install VIP grace by default (see
      // CLAUDE.md), which would short-circuit these checks before ever
      // reaching the throttle this test is proving — disable it.
      firstInstallVipGrace: FirstInstallVipGrace.disabled,
      placements: PlacementRegistry({
        't181_loose': PlacementSpec(
          format: AdSlotType.interstitial,
          minIntervalOverrideMs: 0,
        ),
      }),
    );

Future<void> _waitForInterstitialReady(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().adapter?.interstitialSlot.isReady ?? false) return;
  }
  fail('interstitial never became ready on this real device — cannot '
      'isolate the throttle check from ad-readiness');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'canShowInterstitial(placement: t181_loose) reads true even though '
      'the app-wide throttle alone would block canShowInterstitial() for '
      'the default placement, on a real device with a real loaded ad',
      (tester) async {
    await AdManager().initialize(config: _config(), onComplete: (_, __) {});
    await _waitForInterstitialReady(tester);
    expect(AdManager().isInitialised, isTrue);

    // Simulates "a fullscreen ad was just shown" — same real code path a
    // genuine show/dismiss cycle runs.
    AdSafetyConfig.recordFullscreenAdShown();

    expect(AdManager().canShowInterstitial(placement: _loosePlacement), isTrue,
        reason: 't181_loose\'s registered minIntervalOverrideMs: 0 must let '
            'this through despite the huge app-wide throttle');
    expect(AdManager().canShowInterstitial(), isFalse,
        reason: 'the default (unspecified) placement has no registry '
            'entry — it must still see the huge app-wide throttle '
            'unchanged, on this same real device, same loaded ad');
  });
}
