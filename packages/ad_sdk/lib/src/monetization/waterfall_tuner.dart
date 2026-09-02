import 'dart:async';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';

/// A local recommendation: switch [type]/[placement] to [recommendedProvider]
/// next session, based on trailing fill-rate and eCPM across both providers.
class WaterfallRecommendation {
  const WaterfallRecommendation({
    required this.type,
    required this.placement,
    required this.recommendedProvider,
    required this.currentProvider,
    required this.recommendedScore,
    required this.currentScore,
  });

  final AdSlotType type;
  final AdPlacement placement;

  /// `'[AdMob]'` or `'[AppLovin]'`.
  final String recommendedProvider;
  final String currentProvider;
  final double recommendedScore;
  final double currentScore;
}

/// Opt-in, on-device waterfall tuner (T122) — v1.
///
/// Watches `AdManager().events` for [AdLoadEvent] and [AdRevenueEvent],
/// tracking a trailing fill-rate and average eCPM per (provider, format,
/// placement). It only ever produces a *recommendation* — see
/// [recommendation] — never switches providers itself: this SDK serves one
/// provider per session (see `AdConfig.provider`/`pickProviderCohort()`), so
/// "switching" only makes sense at the next session boundary, and only a
/// host explicitly reading this recommendation and acting on it (e.g.
/// picking `provider:` for its next `initialize()` call) can do that. No
/// shadow ad is ever requested for the non-active provider — every score
/// comes only from load/revenue events the SDK already produces.
///
/// Latency is deliberately not scored: `AdLoadEvent` doesn't carry a
/// timestamp delta today, so there is no real latency signal to rank on
/// yet — scoring on a fabricated one would be worse than not scoring it.
///
/// Completely opt-in via `AdManager().enableWaterfallTuner(...)` — nothing
/// is tracked unless a host app calls that.
///
/// **Round-31 audit — real limitation, read before enabling:** because a
/// single install runs exactly one provider for its whole lifetime (the
/// stable per-install cohort assignment noted above), [_loadResults] and
/// [_revenueMicros] for the NON-active provider are never populated on a
/// real device — no code path in this SDK ever requests a shadow ad from
/// the inactive provider to seed them. [recommendation] therefore compares
/// the active provider's real score against an always-empty score for the
/// other provider, which can never come out ahead — [recommendation]
/// cannot return non-null on a real device, ever, regardless of how much
/// data accumulates. This is not a bug to "fix" by shadow-requesting the
/// other provider (that would burn a real ad request per format per
/// session purely for attribution, a cost/policy tradeoff worth a
/// deliberate decision of its own, not a side effect of enabling this).
/// What this class IS useful for today: an app that runs deliberate
/// provider-cohort A/B experiments ACROSS installs (not within one) can
/// still read [WaterfallTuner]'s per-provider scores from server-side
/// analytics fed by [AdRevenueEvent]/[AdLoadEvent] and decide a NEW
/// install's `AdConfig.provider` from that — just not via [recommendation]
/// itself, which has no cross-provider data to compare within one install.
class WaterfallTuner {
  WaterfallTuner({int rollingWindowSize = 20})
      : _rollingWindowSize = rollingWindowSize {
    _sub = AdManager().events.listen(_onEvent);
  }

  final int _rollingWindowSize;

  final Map<_Key, List<bool>> _loadResults = {};
  final Map<_Key, List<int>> _revenueMicros = {};

  StreamSubscription<AdEvent>? _sub;

  void _onEvent(AdEvent event) {
    if (event is AdLoadEvent) {
      final key = _Key(event.providerTag, event.type, event.placement);
      final list = _loadResults.putIfAbsent(key, () => []);
      list.add(event.success);
      if (list.length > _rollingWindowSize) list.removeAt(0);
    } else if (event is AdRevenueEvent) {
      final key = _Key(event.providerTag, event.type, event.placement);
      final list = _revenueMicros.putIfAbsent(key, () => []);
      list.add(event.valueMicros);
      if (list.length > _rollingWindowSize) list.removeAt(0);
    }
  }

  double _fillRate(_Key key) {
    final results = _loadResults[key];
    if (results == null || results.isEmpty) return 0;
    return results.where((s) => s).length / results.length;
  }

  double _avgEcpmMicros(_Key key) {
    final revenue = _revenueMicros[key];
    if (revenue == null || revenue.isEmpty) return 0;
    return revenue.reduce((a, b) => a + b) / revenue.length;
  }

  /// score = fillRate * avg eCPM — a provider with a great fill rate but
  /// zero revenue (e.g. only ever showing house/PSA creatives) scores no
  /// better than one that rarely fills at all.
  double _score(_Key key) => _fillRate(key) * _avgEcpmMicros(key);

  /// Minimum trailing load attempts (summed across BOTH providers for this
  /// [type]/[placement]) before [recommendation] will suggest anything —
  /// below this there isn't enough history to trust the comparison.
  static const int minSampleSize = 6;

  /// A recommendation to prefer a different provider for [type]/[placement]
  /// next session, or `null` if there isn't enough trailing data yet, the
  /// current provider is already the better (or tied) one, or fewer than
  /// [minSampleSize] attempts have been observed.
  WaterfallRecommendation? recommendation({
    required AdSlotType type,
    required AdPlacement placement,
    required String currentProvider,
  }) {
    final other = currentProvider == '[AdMob]' ? '[AppLovin]' : '[AdMob]';
    final currentKey = _Key(currentProvider, type, placement);
    final otherKey = _Key(other, type, placement);

    final currentAttempts = _loadResults[currentKey]?.length ?? 0;
    final otherAttempts = _loadResults[otherKey]?.length ?? 0;
    if (currentAttempts + otherAttempts < minSampleSize) return null;

    final currentScore = _score(currentKey);
    final otherScore = _score(otherKey);
    if (otherScore <= currentScore) return null;

    return WaterfallRecommendation(
      type: type,
      placement: placement,
      recommendedProvider: other,
      currentProvider: currentProvider,
      recommendedScore: otherScore,
      currentScore: currentScore,
    );
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}

class _Key {
  const _Key(this.provider, this.type, this.placement);
  final String provider;
  final AdSlotType type;
  final AdPlacement placement;

  @override
  bool operator ==(Object other) =>
      other is _Key &&
      other.provider == provider &&
      other.type == type &&
      other.placement == placement;

  @override
  int get hashCode => Object.hash(provider, type, placement);
}
