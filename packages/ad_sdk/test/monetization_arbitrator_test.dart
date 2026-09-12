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

import 'dart:convert';

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
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

  int showInterstitialCalls = 0;
  int showRewardedCalls = 0;
  int showRewardedInterstitialCalls = 0;

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
  Future<void> loadRewardedInterstitial() async {
    rewardedInterstitialSlot.beginReload();
    rewardedInterstitialSlot.markReady();
  }

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    showRewardedInterstitialCalls++;
    rewardedInterstitialSlot.beginShow();
    rewardedInterstitialSlot.markDismissed();
    onDone(const RewardResult(earned: true, label: 'coins', amount: 1));
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdRevenueEvent _rev(int micros,
        {AdSlotType type = AdSlotType.interstitial,
        String currencyCode = 'USD'}) =>
    AdRevenueEvent(
      providerTag: 'fake',
      type: type,
      placement: AdPlacement.unspecified,
      valueMicros: micros,
      currencyCode: currencyCode,
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
      AdManager().debugEmit(_rev(100)); // would be well below any threshold
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
      AdManager().debugEmit(_rev(1000)); // $1.00 CPM equivalent
      AdManager().debugEmit(_rev(3000)); // $3.00 CPM equivalent
      // Broadcast-stream delivery is async (microtask) — flush.
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 2000000); // avg $2.00
      arb.dispose();
    });

    test('rolling window truncates to the last N samples', () async {
      final arb = MonetizationArbitrator(rollingWindowSize: 2);
      AdManager().debugEmit(_rev(10000)); // dropped once window fills
      AdManager().debugEmit(_rev(2000));
      AdManager().debugEmit(_rev(2000));
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 2000000, reason: 'oldest sample evicted');
      arb.dispose();
    });
  });

  group('T58 — eCPM unit conversion (per-impression revenue vs per-mille)', () {
    // AdRevenueEvent.valueMicros is documented as a SINGLE impression's
    // revenue ("$1.23" -> 1_230_000, see ad_event.dart). eCPM is revenue per
    // 1000 impressions, so estimatedEcpmMicros must scale the per-impression
    // average by 1000 -- not return the raw per-impression average as if it
    // were already an eCPM figure.
    test(
        r'a real $5 CPM performance (5_000 micros/impression) reports as '
        '5_000_000 micros eCPM, not 5_000', () async {
      final arb = MonetizationArbitrator();
      // $5 eCPM == $0.005 per single impression == 5_000 micros/impression.
      AdManager().debugEmit(_rev(5000));
      AdManager().debugEmit(_rev(5000));
      await Future<void>.delayed(Duration.zero);

      expect(arb.estimatedEcpmMicros, 5000000,
          reason: r'5_000 micros/impression is a real $5 CPM performance — '
              'reporting it as 5_000 micros would make it look 1000x worse '
              'than it actually is');
      arb.dispose();
    });

    test(
        r'a real $5 CPM performance does not get vetoed at a $5 CPM threshold',
        () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      // Realistic per-impression revenue for a genuine $5 eCPM stream.
      AdManager().debugEmit(_rev(5000));
      await Future<void>.delayed(Duration.zero);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue,
          reason: 'ad actually performing at the threshold eCPM must show, '
              'not be vetoed as if it were 1000x below threshold');
      expect(adapter.showInterstitialCalls, 1);
    });
  });

  group('registered arbitrator crossing to nudgeVip', () {
    test(
        'showInterstitial: native show skipped, ArbitratorNudgeEvent fires, '
        'onDoneFlow(false)', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100)); // $0.10 CPM equivalent — well below threshold
      }
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
      // Round-23 QC (reviewer A, MAJOR) — a slot is priced from its OWN
      // history now, so a veto on this slot has to be fed this slot's
      // revenue. Feeding interstitial revenue and asserting a rewarded
      // veto, as this test used to, is exactly the bug that was fixed.
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
      }
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

    test(
        'showRewardedInterstitialAd (T89 slot): native show skipped, '
        'ArbitratorNudgeEvent fires, onDone(false, false)', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      // Round-23 QC (reviewer A, MAJOR) — a slot is priced from its OWN
      // history now, so a veto on this slot has to be fed this slot's
      // revenue. Feeding interstitial revenue and asserting a rewarded
      // veto, as this test used to, is exactly the bug that was fixed.
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100, type: AdSlotType.rewardedInterstitial));
      }
      await Future<void>.delayed(Duration.zero);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? shown;
      bool? earned;
      await AdManager().showRewardedInterstitialAd(
          onDone: (s, e) {
            shown = s;
            earned = e;
          });

      expect(shown, isFalse, reason: 'vetoed — signals "not shown"');
      expect(earned, isFalse);
      expect(adapter.showRewardedInterstitialCalls, 0,
          reason: 'native show call must be skipped');
      expect(events.whereType<ArbitratorNudgeEvent>(), hasLength(1));
      expect(
          events.whereType<ArbitratorNudgeEvent>().single.type,
          AdSlotType.rewardedInterstitial);

      await sub.cancel();
    });

    test('high trailing eCPM (above threshold) → ad shows normally', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(10000)); // $10 CPM equivalent — above threshold
      }
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
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100));
      }
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
      // Round-23 QC (reviewer A, MAJOR) — a slot is priced from its OWN
      // history now, so a veto on this slot has to be fed this slot's
      // revenue. Feeding interstitial revenue and asserting a rewarded
      // veto, as this test used to, is exactly the bug that was fixed.
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
      }
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
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100)); // low eCPM, would normally nudge
      }
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
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(2000)); // $2 CPM equivalent — below interstitial's $5
      }
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
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100)); // well below threshold — nudges
      }
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
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100));
      }
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
      // Round-24 QC (reviewer B, MAJOR): a bucket thinner than
      // `_minSamplesToPrice` is deliberately not priced at all, so a test that
      // wants the arbitrator to have an opinion has to give it evidence.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(10000)); // $10 CPM equivalent — above threshold
      }
      await Future<void>.delayed(Duration.zero);
      expect(arb.decide(AdSlotType.interstitial), ArbitratorDecision.showAd);
      expect(arb.vetoRate, 0.0,
          reason: 'window now [showAd, showAd] — fully recovered');
      arb.dispose();
    });
  });

  // T138 — decideWithContext() exposes WHY a decision was made (which
  // threshold, what trailing eCPM, whether the guardrail forced it) without
  // changing decide()'s existing enum-only signature (still compared
  // directly at 3 real call sites in ad_manager.dart).
  group('decideWithContext (T138)', () {
    test('no evidence yet (ecpm == 0) → showAd, reason says so', () {
      final arb = MonetizationArbitrator();
      final detail = arb.decideWithContext(AdSlotType.interstitial);
      expect(detail.decision, ArbitratorDecision.showAd);
      expect(detail.trailingEcpmMicros, 0);
      expect(detail.guardrailTripped, isFalse);
      expect(detail.reason.toLowerCase(), contains('no'));
      arb.dispose();
    });

    // Self-caught regression — an earlier draft of this refactor added an
    // `ecpm == 0` short-circuit BEFORE the estimator-registered branch,
    // which skipped calling the registered estimator entirely whenever a
    // slot had no revenue evidence yet. decide()'s pre-T138 behavior always
    // invoked a registered estimator unconditionally (computed before any
    // ecpm check) — this test pins that exact call, independent of
    // ad_crash_guard_test.dart (which is what actually caught the
    // regression, via its own unrelated estimator-throws-during-build
    // scenario, when this session's own full test suite run turned it up).
    test(
        'a registered estimator is ALWAYS invoked when ecpm == 0 too — not '
        'skipped just because there is no revenue evidence yet', () {
      final arb = MonetizationArbitrator();
      var calls = 0;
      arb.registerVipLikelihoodEstimator(() {
        calls++;
        return 0.9;
      });
      arb.decideWithContext(AdSlotType.interstitial);
      expect(calls, 1,
          reason: 'the estimator must be called even when ecpm == 0, '
              'matching decide()\'s original unconditional-call behavior — '
              'a host relying on this call for its own side effects (e.g. '
              'refreshing a cached likelihood value) must not be silently '
              'skipped');
      arb.dispose();
    });

    test('low eCPM, no estimator → nudgeVip, reason cites the threshold',
        () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100));
      }
      await Future<void>.delayed(Duration.zero);

      final detail = arb.decideWithContext(AdSlotType.interstitial);
      expect(detail.decision, ArbitratorDecision.nudgeVip);
      expect(detail.trailingEcpmMicros, 100000);
      expect(detail.thresholdMicros, 5000000);
      expect(detail.guardrailTripped, isFalse);
      expect(detail.reason, isNotEmpty);
      arb.dispose();
    });

    test('high eCPM (above threshold) → showAd', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(10000));
      }
      await Future<void>.delayed(Duration.zero);

      final detail = arb.decideWithContext(AdSlotType.interstitial);
      expect(detail.decision, ArbitratorDecision.showAd);
      expect(detail.trailingEcpmMicros, 10000000);
      arb.dispose();
    });

    test(
        'estimator registered, low likelihood → showAd despite low eCPM, '
        'reason mentions likelihood', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      arb.registerVipLikelihoodEstimator(() => 0.1);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100));
      }
      await Future<void>.delayed(Duration.zero);

      final detail = arb.decideWithContext(AdSlotType.interstitial);
      expect(detail.decision, ArbitratorDecision.showAd);
      expect(detail.reason.toLowerCase(), contains('likelihood'));
      arb.dispose();
    });

    test(
        'estimator registered, high likelihood + low eCPM → nudgeVip, '
        'reason mentions likelihood', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      arb.registerVipLikelihoodEstimator(() => 0.9);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100));
      }
      await Future<void>.delayed(Duration.zero);

      final detail = arb.decideWithContext(AdSlotType.interstitial);
      expect(detail.decision, ArbitratorDecision.nudgeVip);
      expect(detail.reason.toLowerCase(), contains('likelihood'));
      arb.dispose();
    });

    test(
        'an active FillRateBaselineMonitor regression alert flips showAd → '
        'nudgeVip, reason mentions the regression/baseline', () async {
      SharedPreferences.setMockInitialValues({});
      AdPreferences.resetForTest();
      final prefs = await AdPreferences.getInstance();

      // Same seeding shape as fill_rate_baseline_monitor_test.dart's own
      // "fires a fill-rate regression alert" case: a healthy 90% baseline
      // over the last couple of days, then a session running at 20%.
      Future<void> seedPastDay(int daysAgo, int attempts, int successes) async {
        final raw = await SharedPreferences.getInstance();
        final existing = raw.getString('ad_sdk_fill_rate_baseline_history_v1');
        final history = existing == null
            ? <String, dynamic>{}
            : jsonDecode(existing) as Map<String, dynamic>;
        // T165 fix: history is keyed by UTC day (AdPreferences
        // ._todayUtcClamped) — a local-time date here drifts a day off
        // during the daily window where local and UTC calendar dates
        // differ (e.g. any UTC+ timezone shortly after local midnight).
        final date = DateTime.now()
            .toUtc()
            .subtract(Duration(days: daysAgo))
            .toIso8601String()
            .substring(0, 10);
        history[date] = {
          'interstitial': {
            'attempts': attempts,
            'successes': successes,
            'revenueMicros': 0,
            'revenueCount': 0,
          },
        };
        await raw.setString(
            'ad_sdk_fill_rate_baseline_history_v1', jsonEncode(history));
      }

      await seedPastDay(1, 60, 54);
      await seedPastDay(2, 40, 36);

      final monitor = FillRateBaselineMonitor(prefs, minSamples: 5);
      for (final ok in [true, false, false, false, false]) {
        AdManager().debugEmit(AdLoadEvent(
          providerTag: 'fake',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: ok,
        ));
      }
      await Future<void>.delayed(Duration.zero);
      expect(monitor.activeAlerts, contains(AdSlotType.interstitial),
          reason: 'sanity: the monitor must have detected the regression '
              '(20% session vs. 90% baseline)');

      final arb = MonetizationArbitrator(fillRateBaselineMonitor: monitor);
      final detail = arb.decideWithContext(AdSlotType.interstitial);
      expect(detail.decision, ArbitratorDecision.nudgeVip);
      expect(detail.reason.toLowerCase(),
          anyOf(contains('regress'), contains('baseline')));
      monitor.dispose();
      arb.dispose();
    });

    test(
        'guardrail tripping forces showAd, and guardrailTripped/reason '
        'reflect that specifically', () async {
      final arb = MonetizationArbitrator(
        ecpmThresholdMicros: 5000000,
        maxVetoRate: 0.5,
        decisionWindowSize: 2,
      );
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100));
      }
      await Future<void>.delayed(Duration.zero);

      // Fill the decision window at 100% veto via decideWithContext itself
      // (it must record decisions the same way decide() does).
      expect(arb.decideWithContext(AdSlotType.interstitial).decision,
          ArbitratorDecision.nudgeVip);
      expect(arb.decideWithContext(AdSlotType.interstitial).decision,
          ArbitratorDecision.nudgeVip);

      final tripped = arb.decideWithContext(AdSlotType.interstitial);
      expect(tripped.decision, ArbitratorDecision.showAd,
          reason: 'guardrail must force showAd on the 3rd call');
      expect(tripped.guardrailTripped, isTrue);
      expect(tripped.reason.toLowerCase(), contains('guardrail'));
      arb.dispose();
    });

    test(
        'decide() and decideWithContext() agree on the decision for the '
        'exact same arbitrator state — no divergent logic paths', () async {
      // Two separately-constructed, identically-fed arbitrators: one only
      // ever asked via decide(), the other only ever asked via
      // decideWithContext() — proves the shared implementation actually
      // produces the SAME decision either way, without letting one call
      // advance the other's internal _decisions bookkeeping.
      final arbA = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      final arbB = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100));
      }
      await Future<void>.delayed(Duration.zero);
      // Re-emit for arbB — both arbitrators are separately subscribed to
      // the same AdManager().events stream, so both already received the
      // events above; no separate feed needed.

      expect(arbA.decide(AdSlotType.interstitial),
          arbB.decideWithContext(AdSlotType.interstitial).decision);
      arbA.dispose();
      arbB.dispose();
    });
  });

  group('enableArbitrator called twice disposes the previous instance', () {
    test(
        'replaced arbitrator stops receiving revenue events — its stream '
        'subscription was cancelled, not leaked', () async {
      final arb1 = MonetizationArbitrator();
      AdManager().enableArbitrator(arb1);
      AdManager().debugEmit(_rev(1000)); // $1.00 CPM equivalent
      await Future<void>.delayed(Duration.zero);
      expect(arb1.estimatedEcpmMicros, 1000000,
          reason: 'arb1 is active and received the event');

      final arb2 = MonetizationArbitrator();
      AdManager().enableArbitrator(arb2); // must dispose arb1 first

      AdManager().debugEmit(_rev(9000)); // $9.00 CPM equivalent, fed after the swap
      await Future<void>.delayed(Duration.zero);

      expect(arb1.estimatedEcpmMicros, 1000000,
          reason: 'arb1 must be unsubscribed — a leaked subscription would '
              'have updated it to the new average instead');
      expect(arb2.estimatedEcpmMicros, 9000000,
          reason: 'arb2 is now the sole active listener');
    });
  });

  group('T175 — dispose() during an in-flight event', () {
    test(
        'dispose() called in the SAME synchronous turn as debugEmit() means '
        '_onEvent never partially runs — the event is never processed at '
        'all, proving there is no async gap in _onEvent for dispose() to '
        'race against', () async {
      // _onEvent is plain `void` — no `await` inside it anywhere in this
      // class (unlike WaterfallTuner/SelfHealingObserver, which persist to
      // SharedPreferences and so have a real fire-and-forget write dispose()
      // must wait for). AdManager().events is a non-sync broadcast
      // StreamController, so delivery needs at least one microtask turn —
      // calling dispose() here, with no `await` between debugEmit() and it,
      // guarantees the subscription is cancelled before that microtask ever
      // fires _onEvent.
      final arb = MonetizationArbitrator();
      AdManager().debugEmit(_rev(5000));
      arb.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(arb.estimatedEcpmMicros, 0,
          reason: 'T175 — the event emitted right before dispose() must '
              'never have been processed at all: not partially applied, '
              'not applied late after dispose()');
    });

    test(
        'dispose() does not throw and further events after it are silently '
        'ignored, no leaked subscription', () async {
      final arb = MonetizationArbitrator();
      AdManager().debugEmit(_rev(1000));
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 1000000);

      expect(arb.dispose, returnsNormally);

      // Events after dispose() must be silently ignored — not accumulate,
      // not throw.
      AdManager().debugEmit(_rev(9999999));
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 1000000,
          reason: 'a post-dispose event must not reach the now-cancelled '
              'subscription');
    });
  });

  group('T112 — FillRateBaselineMonitor as an additional veto signal', () {
    FillRateBaselineMonitor? monitor;

    tearDown(() => monitor?.dispose());

    test(
        'default (no monitor passed) — an active regression elsewhere has '
        'zero effect, byte-for-byte unchanged behaviour', () async {
      final arb = MonetizationArbitrator(); // no fillRateBaselineMonitor
      // No revenue samples at all for this slot -> ecpm == 0 -> the plain
      // heuristic alone always resolves to showAd, regardless of anything
      // happening in a FillRateBaselineMonitor this arbitrator never sees.
      expect(arb.decide(AdSlotType.interstitial), ArbitratorDecision.showAd);
    });

    test(
        'an active regression alert for this slot nudges VIP even though '
        'the plain eCPM heuristic alone would say showAd', () async {
      // AdPreferences is a process-wide singleton the outer setUp() above
      // already bootstrapped against an earlier (now-irrelevant) mock store
      // — force a truly fresh one so this test's seeded history is what it
      // actually reads, same as fill_rate_baseline_monitor_test.dart.
      AdPreferences.resetForTest();
      // T165 fix: same UTC-day reasoning as seedPastDay above.
      final yesterday = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 1))
          .toIso8601String()
          .substring(0, 10);
      SharedPreferences.setMockInitialValues({
        'ad_sdk_fill_rate_baseline_history_v1':
            '{"$yesterday":{"interstitial":'
                '{"attempts":100,"successes":90,"revenueMicros":0,"revenueCount":0}}}',
      });
      final prefs = await AdPreferences.getInstance();

      monitor = FillRateBaselineMonitor(prefs, minSamples: 3);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(AdLoadEvent(
          providerTag: 'fake',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: false, // 0% session fill rate vs. 90% baseline
        ));
      }
      await Future<void>.delayed(Duration.zero);
      expect(monitor!.activeAlerts, contains(AdSlotType.interstitial),
          reason: 'sanity: the monitor must have actually detected the '
              'regression this test is about, or the assertion below '
              'proves nothing');

      final arb = MonetizationArbitrator(fillRateBaselineMonitor: monitor);
      // No revenue events fed to the ARBITRATOR itself, so its own eCPM
      // heuristic sees ecpm == 0 and would say showAd on its own — the
      // monitor's alert is the only reason this flips to nudgeVip.
      expect(arb.decide(AdSlotType.interstitial),
          ArbitratorDecision.nudgeVip);
      // A different, non-regressed slot must be unaffected.
      expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.showAd);
    });
  });
}

class _FakeVipTrue implements VipManager {
  @override
  bool get isActive => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
