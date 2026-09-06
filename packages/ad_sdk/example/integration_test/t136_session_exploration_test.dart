// T136 on-device integration test — `pickSessionProvider()` really does
// pick the alternate provider, `initialize()` really boots with it, and the
// exploration is really persisted (reconciled) once real VIP status is known
// post-init — proving the whole wiring end to end, not just the pure-Dart
// decision logic already covered by unit tests in
// test/ad_manager_core_test.dart's "pickSessionProvider (T136)" group.
//
// Run with:
//   flutter test integration_test/t136_session_exploration_test.dart -d <device-or-sim-id>

import 'dart:math';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _FixedRandom implements Random {
  _FixedRandom(this._value);
  final double _value;

  @override
  double nextDouble() => _value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

AdConfig _config({required AdProvider provider}) => AdConfig(
      provider: provider,
      admob: const AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      appLovin: AppLovinConfig(
        sdkKey: 'test',
        bannerId: 'test',
        interstitialId: 'test',
        appOpenId: 'test',
        rewardedId: 'test',
      ),
      safety: const AdSafetyParams(dryRun: true),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'a forced explore-roll picks the alternate provider, a real '
      'initialize() boots with it, and the exploration is persisted once '
      'real (non-VIP) status is known', (tester) async {
    // The install cohort is AppLovin here (never actually initialized with
    // — this repo has no real AppLovin SDK key committed, see CLAUDE.md) so
    // the FORCED explore below flips to AdMob, the provider every other
    // integration test in this directory already initializes for real.
    final sessionProvider = await AdManager().pickSessionProvider(
      installCohortProvider: AdProvider.appLovin,
      explorationRate: 1,
      debugRandom: _FixedRandom(0),
    );
    expect(sessionProvider, AdProvider.admob,
        reason: 'sanity: a forced explore must flip away from the install '
            'cohort provider (appLovin)');
    expect(AdManager().debugHasPendingExplorationCommit, isTrue);

    await AdManager().initialize(
      config: _config(provider: sessionProvider),
      onComplete: (_, __) {},
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull,
        reason: 'initialize() with the alternate (explored) provider must '
            'not throw');
    expect(AdManager().isInitialised, isTrue);
    // The real proof this test exists for: a real initialize() cycle
    // really does reach VipManager.load() and calls
    // _reconcileProviderExplorationSlot for real — not just that the two
    // pieces work in isolation (already covered by the fast, deterministic
    // unit tests in ad_manager_core_test.dart's "pickSessionProvider
    // (T136)" group, which control VIP status directly). Whether THIS
    // exploration ends up persisted or discarded depends on this real
    // device's actual VIP status (debug builds grant first-install grace —
    // see CLAUDE.md — which is itself time-window-dependent and not
    // reliably controllable from an on-device test without clearing app
    // data between runs), so only the "reconciled, not left dangling"
    // outcome is asserted here.
    expect(AdManager().debugHasPendingExplorationCommit, isFalse,
        reason: 'a real initialize() cycle must reach VipManager.load() and '
            'reconcile the pending exploration one way or the other — '
            'never leave it pending forever');
  });
}
