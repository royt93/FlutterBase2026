// T140 on-device integration test — a real showInterstitial() call, on a
// real device, gets skipped with reason 'placement_cap' when
// PlacementRegistry's frequencyCapOverride for that placement is already
// reached — end to end through a real initialize(), not just the
// debugConfig-seeded unit tests in test/ad_manager_core_test.dart.
//
// Run with:
//   flutter test integration_test/t140_placement_registry_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _interstitialPlacement = AdPlacement.custom('level_complete');
const _rewardedPlacement = AdPlacement.custom('reward_shop');

AdConfig _config() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
      // Debug builds grant first-install VIP grace by default (see
      // CLAUDE.md), which would short-circuit these show calls before
      // ever reaching the placement_cap check this test is proving —
      // disable it so this test only exercises T140's own gate.
      firstInstallVipGrace: FirstInstallVipGrace.disabled,
      placements: PlacementRegistry({
        'level_complete': PlacementSpec(
          format: AdSlotType.interstitial,
          frequencyCapOverride: 1,
        ),
        'reward_shop': PlacementSpec(
          format: AdSlotType.rewarded,
          frequencyCapOverride: 1,
        ),
      }),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'a real showInterstitial() call is skipped for placement_cap once '
      'the registry\'s frequencyCapOverride is reached', (tester) async {
    await AdManager().initialize(config: _config(), onComplete: (_, _) {});
    await tester.pump(const Duration(milliseconds: 300));
    expect(AdManager().isInitialised, isTrue);

    AdSafetyConfig.recordPlacementAdShown(_interstitialPlacement);

    AdSkipEvent? skip;
    final sub = AdManager().events.listen((e) {
      if (e is AdSkipEvent) skip = e;
    });
    addTearDown(sub.cancel);

    await AdManager().showInterstitial(
      onDoneFlow: (_) {},
      placement: _interstitialPlacement,
    );
    await tester.pump();

    expect(skip, isNotNull);
    expect(skip!.reason, 'placement_cap',
        reason: 'a real device run must actually resolve '
            'AdConfig.placements through to a real showInterstitial() '
            'call and skip it — not just in a debugConfig-seeded unit '
            'test');
  });

  // Round-2 independent review — the same gate wired through a SECOND
  // format's real show call, not just interstitial, to prove the
  // per-call format check (`_placementCapOverride`) actually resolves the
  // correct spec on a real device too.
  testWidgets(
      'a real showRewardedAd() call is also skipped for placement_cap '
      'once its registered frequencyCapOverride is reached', (tester) async {
    await AdManager().initialize(config: _config(), onComplete: (_, _) {});
    await tester.pump(const Duration(milliseconds: 300));
    expect(AdManager().isInitialised, isTrue);

    AdSafetyConfig.recordPlacementAdShown(_rewardedPlacement);

    AdSkipEvent? skip;
    final sub = AdManager().events.listen((e) {
      if (e is AdSkipEvent) skip = e;
    });
    addTearDown(sub.cancel);

    await AdManager().showRewardedAd(
      onEarnedReward: (_) {},
      placement: _rewardedPlacement,
    );
    await tester.pump();

    expect(skip, isNotNull);
    expect(skip!.reason, 'placement_cap',
        reason: 'a real device run of a DIFFERENT format (rewarded, not '
            'just interstitial) must also resolve its own registered '
            'spec correctly');
  });
}
