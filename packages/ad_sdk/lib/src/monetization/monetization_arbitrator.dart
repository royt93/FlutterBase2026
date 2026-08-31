import 'dart:async';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'fill_rate_baseline_monitor.dart';

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
    FillRateBaselineMonitor? fillRateBaselineMonitor,
  })  : _perSlotThresholdMicros = perSlotThresholdMicros,
        _rollingWindowSize = rollingWindowSize,
        _decisionWindowSize = decisionWindowSize,
        _fillRateBaselineMonitor = fillRateBaselineMonitor {
    _sub = AdManager().events.listen(_onEvent);
  }

  /// T112 — opt-in only: `null` (the default) leaves every decision exactly
  /// as it was before this field existed. When set, an active regression
  /// alert (T97 — this slot's fill-rate/eCPM has dropped notably below its
  /// own 7-day baseline) is treated as an ADDITIONAL veto signal in
  /// [decide], on top of the plain eCPM-vs-threshold heuristic: the
  /// arbitrator was "blind" to a regression it already knows about from a
  /// different feature.
  final FillRateBaselineMonitor? _fillRateBaselineMonitor;

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
  ///
  /// Diagnostic pool only. [decide] does NOT read this — see
  /// [_samplesByBucket] and the round-23 note on [estimatedEcpmMicrosFor].
  final List<int> _samples = [];

  /// Round-23 QC (reviewer A, MAJOR) — the same samples, but split by
  /// `'<slot>|<currency>'`.
  ///
  /// The single pool above answers "what has this app earned recently",
  /// which is not the question [decide] asks. A feed emitting a hundred
  /// cheap banner impressions used to drag the trailing average below the
  /// *rewarded* threshold and veto a genuinely profitable rewarded show —
  /// straight lost revenue, and a nudge event reporting an eCPM that had
  /// nothing to do with the format being priced. Mixing currencies had the
  /// same shape: an account paid in a non-USD currency was compared against a
  /// threshold documented in dollars.
  final Map<String, List<int>> _samplesByBucket = {};

  /// Most recently observed currency per slot type. A publisher's account
  /// reports one currency in practice; this exists so a stray event in
  /// another currency cannot be averaged in with it.
  final Map<AdSlotType, String> _lastCurrencyBySlot = {};

  static String _bucketKey(AdSlotType type, String currencyCode) =>
      '${type.name}|$currencyCode';

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
      final bucket = _samplesByBucket.putIfAbsent(
          _bucketKey(event.type, event.currencyCode), () => <int>[]);
      bucket.add(event.valueMicros);
      if (bucket.length > _rollingWindowSize) {
        bucket.removeAt(0);
      }
      _lastCurrencyBySlot[event.type] = event.currencyCode;
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
  ///
  /// [AdRevenueEvent.valueMicros] is a single impression's revenue (T58: the
  /// average of those is a per-impression figure, not an eCPM — eCPM is
  /// revenue per *1000* impressions), so the per-impression average is
  /// scaled by 1000 to become comparable to [ecpmThresholdMicros].
  /// **Diagnostic only.** This averages every format and every currency the
  /// session has seen. Since round-23 it is no longer what [decide] consults
  /// — use [estimatedEcpmMicrosFor] for anything that gates a show.
  int get estimatedEcpmMicros {
    if (_samples.isEmpty) return 0;
    final sum = _samples.fold<int>(0, (a, b) => a + b);
    return sum * 1000 ~/ _samples.length;
  }

  /// Trailing eCPM estimate for [slot] alone, in the currency that slot was
  /// most recently paid in. `0` when this slot has produced no revenue events
  /// yet — and `0` means "no evidence", which [decide] treats as *show*, never
  /// as *cheap*.
  ///
  /// Round-23 QC (reviewer A, MAJOR): pricing a rewarded opportunity off a
  /// feed's banner revenue vetoed profitable impressions. A format is only
  /// ever compared against its own history now.
  ///
  /// Round-28 QC (reviewer B, MINOR) — what a currency change actually does,
  /// stated rather than implied. The slot reads the bucket for the currency it
  /// was *most recently* paid in, so an account that starts being paid in a new
  /// currency resets that slot's pricing: it fails open (shows the ad) until
  /// five samples accumulate in the new currency. The old currency's history is
  /// kept, not discarded, and is read again if payment reverts. Deliberate —
  /// blending two currencies is the bug this fix exists to stop, and failing
  /// open for a few impressions costs less than comparing dong against a
  /// threshold written in dollars.
  /// Round-24 QC (reviewer B, MAJOR): splitting the pool per format was the
  /// right call, but it made each bucket fill hundreds of times more slowly
  /// than the old all-formats pool did — so a rewarded bucket sits at n=1 for a
  /// long stretch of a session. Pricing off that one sample let a single cheap
  /// backfill or house ad veto the format for the rest of the session, and the
  /// loop self-latched: a vetoed show emits no revenue event, so the bucket
  /// could never grow past the bad sample that caused the veto. The
  /// [maxVetoRate] guardrail eventually broke the latch, but only after 20
  /// consecutive vetoes, and then it oscillated.
  ///
  /// Five is not a statistical claim; it is "more than a fluke". Below it, the
  /// bucket returns `0` — "no evidence" — which [decide] already treats as
  /// *show*. Failing open on thin data is the only safe direction: the cost of
  /// showing one cheap ad is one cheap ad, the cost of vetoing wrongly is every
  /// rewarded impression for the rest of the session.
  static const int _minSamplesToPrice = 5;

  /// Round-25 QC (reviewer A, MINOR) — clamped to the configured window.
  /// `rollingWindowSize` is a public constructor argument and a host is allowed
  /// to set it to 1–4; the bucket is truncated to that size, so a flat
  /// requirement of five would mean such a host could never be priced at all
  /// and their arbitrator silently did nothing for the life of the session.
  /// Asking for more evidence than the host has agreed to keep is a
  /// configuration error we would be committing on their behalf.
  ///
  /// Round-26 QC (both reviewers, MINOR) — clamped at 1 as well. The first cut
  /// clamped only downward, so `rollingWindowSize: 0` gave a warm-up of 0: an
  /// empty bucket then "qualified" and the average divided by zero. A public
  /// constructor knob must not be able to crash the SDK, and a window of zero
  /// is a host mistake to survive, not one to punish.
  int get _warmUpSamples {
    if (_rollingWindowSize < 1) return 1;
    return _rollingWindowSize < _minSamplesToPrice
        ? _rollingWindowSize
        : _minSamplesToPrice;
  }

  int estimatedEcpmMicrosFor(AdSlotType slot) {
    final currency = _lastCurrencyBySlot[slot];
    if (currency == null) return 0;
    final bucket = _samplesByBucket[_bucketKey(slot, currency)];
    if (bucket == null || bucket.length < _warmUpSamples) return 0;
    final sum = bucket.fold<int>(0, (a, b) => a + b);
    return sum * 1000 ~/ bucket.length;
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
    // Round-23 QC (reviewer A, MAJOR) — this slot's own history, in this
    // slot's own currency. `0` (no samples for it yet) fails open to showAd
    // below, which is the right direction: never suppress revenue on no
    // evidence.
    final ecpm = estimatedEcpmMicrosFor(slot);
    final estimator = _vipLikelihoodEstimator;
    ArbitratorDecision decision;
    if (estimator == null) {
      decision = ecpm > 0 && ecpm < threshold
          ? ArbitratorDecision.nudgeVip
          : ArbitratorDecision.showAd;
    } else {
      final likelihood = estimator();
      decision = (ecpm > 0 && ecpm < threshold && likelihood > 0.5)
          ? ArbitratorDecision.nudgeVip
          : ArbitratorDecision.showAd;
    }

    // T112 — opt-in additional veto signal: a slot already flagged as
    // regressed against its own 7-day baseline (T97) nudges VIP even if the
    // plain eCPM-vs-threshold heuristic above didn't trip on its own. Still
    // subject to the SAME guardrail below — a runaway/misconfigured
    // regression detector can't bypass the vetoRate safety net either.
    if (decision == ArbitratorDecision.showAd &&
        _fillRateBaselineMonitor?.activeAlerts.containsKey(slot) == true) {
      decision = ArbitratorDecision.nudgeVip;
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
