import 'dart:async';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import 'waterfall_tuner.dart';

/// T127 — flagship self-healing dual-provider runtime, **observe-only**
/// prototype (default OFF — see `AdManager().enableSelfHealingObserver`).
///
/// Watches `AdManager().events` and, using its own internal [WaterfallTuner]
/// instance (same fill-rate×eCPM scoring T122 already ships), emits an
/// [AdSelfHealingObserveEvent] onto that SAME stream the first time a
/// (format, placement) pair's trailing data recommends a different provider.
///
/// Deliberately never switches anything itself: the SDK still serves exactly
/// one provider per session (`AdConfig.provider`). Acting on the
/// recommendation for real would need both adapters alive in the same
/// session — a real architecture change out of scope for this prototype,
/// left for a dedicated follow-up ticket once observe-only data validates
/// the idea is worth building.
class SelfHealingObserver {
  SelfHealingObserver({int rollingWindowSize = 20})
      : _tuner = WaterfallTuner(rollingWindowSize: rollingWindowSize) {
    _sub = AdManager().events.listen(_onEvent);
  }

  final WaterfallTuner _tuner;
  StreamSubscription<AdEvent>? _sub;

  /// One observation per (type, placement, recommendedProvider) — once
  /// logged, a recommendation that keeps holding across later events isn't
  /// re-reported every time. Cleared implicitly on [dispose] (a fresh
  /// instance starts with a clean slate).
  final Set<String> _alreadyObserved = {};

  void _onEvent(AdEvent event) {
    if (event is! AdLoadEvent && event is! AdRevenueEvent) return;
    final currentProvider = AdManager().adapter?.tag;
    if (currentProvider == null) return;
    final rec = _tuner.recommendation(
      type: event.type,
      placement: event.placement,
      currentProvider: currentProvider,
    );
    if (rec == null) return;
    final key =
        '${rec.type.name}|${rec.placement.id}|${rec.recommendedProvider}';
    if (!_alreadyObserved.add(key)) return;
    AdManager().emitSelfHealingObservation(rec);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _tuner.dispose();
  }
}
