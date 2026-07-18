import 'dart:async';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';

/// Decision returned by [MonetizationArbitrator.decide].
enum ArbitratorDecision {
  /// Proceed with the native ad show call as normal.
  showAd,

  /// Veto the ad show; the host app should nudge the user toward VIP instead.
  nudgeVip,
}

/// Opt-in "Smart Monetization Arbitrator" — v1.
///
/// At each fullscreen ad-show attempt (after all existing gates, including
/// [AdSafetyConfig]'s safety check, already pass) this decides whether the ad
/// is actually worth showing versus vetoing it in favor of a VIP upsell nudge.
///
/// The decision is a **simple configurable eCPM threshold rule — not machine
/// learning**. It compares a trailing eCPM estimate (built from
/// [AdRevenueEvent]s the SDK already emits) against an optional
/// VIP-conversion-likelihood signal the host app supplies (the SDK has no
/// visibility into the partner's purchase funnel, so it cannot compute this
/// itself).
///
/// Completely opt-in: [AdManager().arbitrator] is `null` until the host app
/// calls `AdManager().enableArbitrator(...)`. Nothing in this class is
/// consulted by the SDK unless that happens.
class MonetizationArbitrator {
  MonetizationArbitrator({
    this.ecpmThresholdMicros =
        5000000, // $5.00 eCPM — v1 default, tune per app.
    Map<AdSlotType, int> perSlotThresholdMicros = const {},
    this.maxVetoRate = 0.5,
    int rollingWindowSize = 20,
    int decisionWindowSize = 20,
  })  : _perSlotThresholdMicros = perSlotThresholdMicros,
        _rollingWindowSize = rollingWindowSize,
        _decisionWindowSize = decisionWindowSize {
    _sub = AdManager().events.listen(_onEvent);
  }

  /// Below this trailing eCPM (in micros per impression, i.e. "value if this
  /// were a $1000-impression eCPM stat"), the arbitrator favors nudging VIP
  /// over showing a low-value ad — unless a registered likelihood estimator
  /// says the user is unlikely to convert anyway.
  ///
  /// Used as the fallback threshold for any slot not present in
  /// [_perSlotThresholdMicros].
  final int ecpmThresholdMicros;

  /// Above this fraction of vetoed decisions (within the trailing
  /// [_decisionWindowSize] calls to [decide]), the guardrail trips: it
  /// assumes the threshold is misconfigured (or eCPM is globally depressed)
  /// and forces [ArbitratorDecision.showAd] rather than keep starving the
  /// user of ads. Recovers automatically once the veto rate drops back down.
  final double maxVetoRate;

  final Map<AdSlotType, int> _perSlotThresholdMicros;
  final int _rollingWindowSize;
  final int _decisionWindowSize;

  /// Trailing revenue-per-impression samples, most-recent last. Session-only
  /// — no persistence across app restarts (v1: not worth it, see class doc).
  final List<int> _samples = [];

  /// Trailing decide() outcomes (true = vetoed), most-recent last. Feeds the
  /// [maxVetoRate] guardrail below.
  final List<bool> _decisions = [];

  /// Whether the guardrail is currently overriding nudges to showAd — tracked
  /// so the warning below logs once per trip, not once per decide() call.
  bool _guardrailTripped = false;

  double Function()? _vipLikelihoodEstimator;

  StreamSubscription<AdEvent>? _sub;

  void _onEvent(AdEvent event) {
    if (event is AdRevenueEvent) {
      _samples.add(event.valueMicros);
      // ponytail: simple List truncation, no ring buffer — 20 ints is nothing.
      if (_samples.length > _rollingWindowSize) {
        _samples.removeAt(0);
      }
    }
  }

  /// Host app supplies a callback returning its own VIP-conversion-likelihood
  /// signal (e.g. `0.0`–`1.0`, higher = more likely to convert). The SDK has
  /// no purchase-funnel visibility, so this must come from the host.
  ///
  /// Pass `null` to clear a previously-registered estimator (falls back to
  /// the plain eCPM-threshold heuristic below).
  void registerVipLikelihoodEstimator(double Function()? estimator) {
    _vipLikelihoodEstimator = estimator;
  }

  /// Trailing eCPM estimate in micros, averaged over the last
  /// [_rollingWindowSize] [AdRevenueEvent]s seen this session. `0` if no
  /// revenue events have been observed yet.
  int get estimatedEcpmMicros {
    if (_samples.isEmpty) return 0;
    final sum = _samples.fold<int>(0, (a, b) => a + b);
    return sum ~/ _samples.length;
  }

  /// Current veto rate over the trailing [_decisionWindowSize] [decide]
  /// calls (vetoed / total). `0` if no decisions have been made yet.
  double get vetoRate {
    if (_decisions.isEmpty) return 0;
    return _decisions.where((v) => v).length / _decisions.length;
  }

  /// Decide whether to show the ad for [slot] or veto it in favor of a VIP
  /// nudge.
  ///
  /// v1 heuristic (NOT machine learning): if a likelihood estimator is
  /// registered and reports a high conversion likelihood (> 0.5) while
  /// trailing eCPM is below the threshold for [slot] (see
  /// [_perSlotThresholdMicros], falling back to [ecpmThresholdMicros]), nudge
  /// VIP instead of showing a low-value ad to a user who's likely to convert
  /// anyway. With no estimator registered, fall back to the plain "eCPM below
  /// threshold" check.
  ///
  /// Guardrail: if the trailing veto rate over the last [_decisionWindowSize]
  /// decisions exceeds [maxVetoRate], this call is forced to [showAd]
  /// regardless of the heuristic above — a misconfigured/too-high threshold
  /// should never be allowed to suppress ads indefinitely.
  ArbitratorDecision decide(AdSlotType slot) {
    final threshold = _perSlotThresholdMicros[slot] ?? ecpmThresholdMicros;
    final ecpm = estimatedEcpmMicros;
    final estimator = _vipLikelihoodEstimator;
    ArbitratorDecision decision;
    if (estimator == null) {
      decision = ecpm > 0 && ecpm < threshold
          ? ArbitratorDecision.nudgeVip
          : ArbitratorDecision.showAd;
    } else {
      final likelihood = estimator();
      decision = (ecpm < threshold && likelihood > 0.5)
          ? ArbitratorDecision.nudgeVip
          : ArbitratorDecision.showAd;
    }

    if (decision == ArbitratorDecision.nudgeVip &&
        _decisions.length >= _decisionWindowSize &&
        vetoRate > maxVetoRate) {
      decision = ArbitratorDecision.showAd;
      if (!_guardrailTripped) {
        _guardrailTripped = true;
        SafeLogger.w('MonetizationArbitrator',
            '⚠️ arbitrator guardrail tripped (vetoRate=$vetoRate > $maxVetoRate) — vetoing too often, falling back to showAd');
      }
    } else if (vetoRate <= maxVetoRate) {
      _guardrailTripped = false;
    }

    _decisions.add(decision == ArbitratorDecision.nudgeVip);
    if (_decisions.length > _decisionWindowSize) {
      _decisions.removeAt(0);
    }
    return decision;
  }

  /// Release the internal [AdManager().events] subscription. Call this if
  /// you ever swap out or disable the arbitrator mid-session.
  void dispose() {
    _sub?.cancel();
  }
}
