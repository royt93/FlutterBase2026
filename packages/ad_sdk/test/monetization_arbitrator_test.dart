// Behavioral tests for the opt-in Smart Monetization Arbitrator, driven
// through the same @visibleForTesting seams as ad_manager_core_test.dart
// (debugSetAdapter / debugEmit) so the two choke points (showInterstitial /
// showRewardedAd) are exercised without native plugins.
//
// Covered:
//   1. Default (arbitrator == null) is a byte-for-byte no-op — the exact
//      same show-ad scenarios as the pre-existing ad_manager tests, with
//      identical outcomes.
//   2. Trailing eCPM computed correctly from a sequence of synthetic
//      AdRevenueEvents fed via debugEmit.
//   3. Registered arbitrator whose decision crosses to nudgeVip: native show
//      is skipped, ArbitratorNudgeEvent fires on events, and the completion
//      callback signals "not shown" exactly like other early-exit gates.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

/// Same minimal fake adapter shape as ad_manager_core_test.dart — real slots
/// so slot reads work, call counters for the load/show paths.
class _FakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int showInterstitialCalls = 0;
  int showRewardedCalls = 0;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadInterstitial() async {}

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    onDone(true);
  }

  @override
  Future<void> loadRewarded() async {
    rewardedSlot.beginReload();
    rewardedSlot.markReady();
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(const RewardResult(earned: true, label: 'coins', amount: 1));
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdRevenueEvent _rev(int micros) => AdRevenueEvent(
      providerTag: 'fake',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: micros,
      currencyCode: 'USD',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
  });

  late _FakeAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    // Permissive safety so the fullscreen gate never blocks the show path
    // under test — isolates the arbitrator veto as the only variable.
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    adapter = _FakeAdapter();
    AdManager().debugSetAdapter(adapter);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
    AdManager().disableArbitrator();
  });

  group('default (no arbitrator registered) — zero behavior change', () {
    test('arbitrator getter is null by default', () {
      expect(AdManager().arbitrator, isNull);
    });

    test('showInterstitial shows exactly as before', () async {
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue);
      expect(adapter.showInterstitialCalls, 1);
    });

    test('showRewardedAd shows exactly as before', () async {
      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);
      expect(earned, isTrue);
      expect(adapter.showRewardedCalls, 1);
    });

    test('feeding revenue events with no arbitrator registered changes nothing',
        () async {
      AdManager().debugEmit(_rev(100000)); // would be well below any threshold
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue,
          reason: 'no arbitrator → events are never consulted');
      expect(adapter.showInterstitialCalls, 1);
    });
  });

  group('trailing eCPM computation (via debugEmit)', () {
    test('estimatedEcpmMicros is 0 with no revenue events', () {
      final arb = MonetizationArbitrator();
      expect(arb.estimatedEcpmMicros, 0);
      arb.dispose();
    });

    test('averages a sequence of AdRevenueEvents', () async {
      final arb = MonetizationArbitrator();
      AdManager().debugEmit(_rev(1000000)); // $1.00
      AdManager().debugEmit(_rev(3000000)); // $3.00
      // Broadcast-stream delivery is async (microtask) — flush.
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 2000000); // avg $2.00
      arb.dispose();
    });

    test('rolling window truncates to the last N samples', () async {
      final arb = MonetizationArbitrator(rollingWindowSize: 2);
      AdManager().debugEmit(_rev(10000000)); // dropped once window fills
      AdManager().debugEmit(_rev(2000000));
      AdManager().debugEmit(_rev(2000000));
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 2000000, reason: 'oldest sample evicted');
      arb.dispose();
    });
  });

  group('registered arbitrator crossing to nudgeVip', () {
    test(
        'showInterstitial: native show skipped, ArbitratorNudgeEvent fires, '
        'onDoneFlow(false)', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000)); // $0.10 — well below threshold
      await Future<void>.delayed(Duration.zero);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);

      expect(flow, isFalse, reason: 'vetoed — signals "not shown"');
      expect(adapter.showInterstitialCalls, 0,
          reason: 'native show call must be skipped');
      expect(events.whereType<ArbitratorNudgeEvent>(), hasLength(1));
      expect(
          events.whereType<ArbitratorNudgeEvent>().single.estimatedEcpmMicros,
          100000);

      await sub.cancel();
    });

    test(
        'showRewardedAd: native show skipped, ArbitratorNudgeEvent fires, '
        'onEarnedReward(false)', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000));
      await Future<void>.delayed(Duration.zero);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);

      expect(earned, isFalse);
      expect(adapter.showRewardedCalls, 0);
      expect(events.whereType<ArbitratorNudgeEvent>(), hasLength(1));

      await sub.cancel();
    });

    test('high trailing eCPM (above threshold) → ad shows normally', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(10000000)); // $10 — above threshold
      await Future<void>.delayed(Duration.zero);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue);
      expect(adapter.showInterstitialCalls, 1);
    });

    test(
        'registered VIP-likelihood estimator: high likelihood + low eCPM → '
        'nudgeVip', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      arb.registerVipLikelihoodEstimator(() => 0.9);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000));
      await Future<void>.delayed(Duration.zero);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isFalse);
      expect(adapter.showInterstitialCalls, 0);
    });

    test(
        'registered VIP-likelihood estimator: low likelihood → ad shows '
        'despite low eCPM', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      arb.registerVipLikelihoodEstimator(() => 0.1);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000));
      await Future<void>.delayed(Duration.zero);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue);
      expect(adapter.showInterstitialCalls, 1);
    });

    test(
        'showRewardedAd VIP-bypass path (bypassVipGuard) is never vetoed by '
        'the arbitrator — watch-ad-to-extend-VIP always proceeds', () async {
      AdManager().debugVipManager = _FakeVipTrue();
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000)); // low eCPM, would normally nudge
      await Future<void>.delayed(Duration.zero);

      bool? earned;
      await AdManager().showRewardedAd(
          bypassVipGuard: true, onEarnedReward: (e) => earned = e);
      expect(earned, isTrue);
      expect(adapter.showRewardedCalls, 1,
          reason: 'VIP watch-ad-to-extend flow must never be vetoed');
    });
  });

  group('per-slot threshold', () {
    test(
        'interstitial has its own threshold — same eCPM nudges interstitial '
        'but shows rewarded', () async {
      final arb = MonetizationArbitrator(
        ecpmThresholdMicros: 1000000, // $1 default — too low to matter here
        perSlotThresholdMicros: {AdSlotType.interstitial: 5000000},
      );
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(2000000)); // $2 — below interstitial's $5
      await Future<void>.delayed(Duration.zero);

      bool? interstitialFlow;
      await AdManager()
          .showInterstitial(onDoneFlow: (v) => interstitialFlow = v);
      expect(interstitialFlow, isFalse,
          reason: 'interstitial threshold (\$5) not met by \$2 eCPM');
      expect(adapter.showInterstitialCalls, 0);

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);
      expect(earned, isTrue,
          reason: 'rewarded falls back to the \$1 default threshold, met');
      expect(adapter.showRewardedCalls, 1);
    });
  });

  group('veto-rate guardrail', () {
    test(
        'after enough consecutive vetoes cross maxVetoRate, guardrail forces '
        'showAd instead of nudgeVip', () async {
      final arb = MonetizationArbitrator(
        ecpmThresholdMicros: 5000000,
        maxVetoRate: 0.5,
        decisionWindowSize: 4,
      );
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000)); // well below threshold — nudges
      await Future<void>.delayed(Duration.zero);

      // First 4 calls fill the decision window: veto rate hits 100% only
      // once >= decisionWindowSize decisions have been recorded, so the
      // guardrail can only trip starting on the call that would make the
      // window full and over threshold.
      final outcomes = <bool?>[];
      for (var i = 0; i < 4; i++) {
        bool? flow;
        await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
        outcomes.add(flow);
      }
      expect(outcomes, [false, false, false, false],
          reason: 'window not yet at decisionWindowSize on the 4th call — '
              'guardrail check only applies once length >= window');

      // 5th call: window is full (4 decisions, all vetoed), veto rate 100%
      // > 50% → guardrail forces showAd.
      bool? flow5;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow5 = v);
      expect(flow5, isTrue,
          reason: 'guardrail tripped — forced showAd despite low eCPM');
      expect(adapter.showInterstitialCalls, 1);
    });

    test('guardrail recovers once veto rate drops back under maxVetoRate',
        () async {
      final arb = MonetizationArbitrator(
        ecpmThresholdMicros: 5000000,
        maxVetoRate: 0.5,
        decisionWindowSize: 2,
      );

      // Direct decide() calls — this test is about MonetizationArbitrator's
      // own bookkeeping, not the AdManager pipeline (already covered above),
      // so it skips AdSafetyConfig's fullscreen-show throttle entirely.

      // Low eCPM → first 2 decisions veto, filling the window at 100%.
      AdManager().debugEmit(_rev(100000));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 2; i++) {
        expect(
            arb.decide(AdSlotType.interstitial), ArbitratorDecision.nudgeVip);
      }
      expect(arb.vetoRate, 1.0);

      // 3rd decision: guardrail trips (forced showAd), which itself records
      // as a non-veto — window becomes [veto, showAd], rate drops to 50%,
      // no longer > maxVetoRate.
      expect(arb.decide(AdSlotType.interstitial), ArbitratorDecision.showAd,
          reason: 'guardrail trips on the 3rd call');
      expect(arb.vetoRate, 0.5);

      // Now raise eCPM above threshold — decisions naturally showAd from
      // here on, so the window stays recovered without guardrail help.
      AdManager().debugEmit(_rev(10000000)); // $10 — above threshold
      await Future<void>.delayed(Duration.zero);
      expect(arb.decide(AdSlotType.interstitial), ArbitratorDecision.showAd);
      expect(arb.vetoRate, 0.0,
          reason: 'window now [showAd, showAd] — fully recovered');
      arb.dispose();
    });
  });

  group('enableArbitrator called twice disposes the previous instance', () {
    test(
        'replaced arbitrator stops receiving revenue events — its stream '
        'subscription was cancelled, not leaked', () async {
      final arb1 = MonetizationArbitrator();
      AdManager().enableArbitrator(arb1);
      AdManager().debugEmit(_rev(1000000)); // $1.00
      await Future<void>.delayed(Duration.zero);
      expect(arb1.estimatedEcpmMicros, 1000000,
          reason: 'arb1 is active and received the event');

      final arb2 = MonetizationArbitrator();
      AdManager().enableArbitrator(arb2); // must dispose arb1 first

      AdManager().debugEmit(_rev(9000000)); // $9.00, fed after the swap
      await Future<void>.delayed(Duration.zero);

      expect(arb1.estimatedEcpmMicros, 1000000,
          reason: 'arb1 must be unsubscribed — a leaked subscription would '
              'have updated it to the new average instead');
      expect(arb2.estimatedEcpmMicros, 9000000,
          reason: 'arb2 is now the sole active listener');
    });
  });
}

class _FakeVipTrue implements VipManager {
  @override
  bool get isActive => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
