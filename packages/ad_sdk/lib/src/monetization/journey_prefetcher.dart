import 'dart:async';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';

/// T123 — opt-in on-device smart prefetch (v1).
///
/// Host apps call [notifySignal] at points in their own user journey that
/// typically precede showing a fullscreen ad (e.g. `"levelStarted"`,
/// `"screenEntered"`) along with the [AdSlotType] expected next. The first
/// time a signal fires for a given (signal, type) pair nothing is known
/// yet, so it preloads immediately — better ready than not. Every matching
/// `AdShowEvent` afterwards records how long ago the last matching signal
/// fired and folds that into a rolling average. Once that average exceeds
/// [maxHoldDuration], later firings of the same signal stop preloading —
/// this signal precedes the show by too long to be worth holding an ad for.
///
/// Never bypasses any safety/consent/VIP gate: [notifySignal] only ever
/// calls the SAME public `AdManager().loadX()` a host could call directly,
/// so every existing gate inside those still applies unchanged. Scoped to
/// the 4 fullscreen formats — banner/MREC/native are per-widget-instance,
/// not a single global slot, so "prefetch on signal" doesn't map onto them
/// the same way.
///
/// Completely opt-in via `AdManager().enableJourneyPrefetcher(...)` —
/// nothing is tracked and nothing is preloaded unless a host app calls
/// [notifySignal] itself.
class JourneyPrefetcher {
  JourneyPrefetcher({this.maxHoldDuration = const Duration(minutes: 5)}) {
    _sub = AdManager().events.listen(_onEvent);
  }

  /// If the rolling average time-to-show for a (signal, type) pair would
  /// leave a preloaded ad sitting unused longer than this, [notifySignal]
  /// stops preloading eagerly for it — avoids holding a stale-feeling ad
  /// (and burning cap/impression budget) for a show that isn't imminent.
  final Duration maxHoldDuration;

  final Map<String, DateTime> _lastSignalAt = {};
  final Map<String, List<Duration>> _timeToShow = {};
  static const int _rollingWindowSize = 10;

  StreamSubscription<AdEvent>? _sub;

  String _key(String signal, AdSlotType type) => '$signal|${type.name}';

  /// A single show can only have been preceded by ONE signal — matching
  /// every pending signal for [type] (as opposed to just the most recent
  /// one) would credit this one show as a sample for every one of them,
  /// conflating timing data between journey signals that have nothing to do
  /// with each other (e.g. `"levelStarted"` and `"screenEntered"` both
  /// pending for the same ad type at once). Only the most-recently-fired
  /// pending signal for this type is resolved; an older, still-pending
  /// signal for a different key is left alone rather than guessed at.
  void _onEvent(AdEvent event) {
    if (event is! AdShowEvent || !event.success) return;
    String? latestKey;
    DateTime? latestAt;
    for (final entry in _lastSignalAt.entries) {
      final parts = entry.key.split('|');
      if (parts.length != 2 || parts[1] != event.type.name) continue;
      if (latestAt == null || entry.value.isAfter(latestAt)) {
        latestAt = entry.value;
        latestKey = entry.key;
      }
    }
    if (latestKey == null || latestAt == null) return;
    final elapsed = DateTime.now().difference(latestAt);
    final samples = _timeToShow.putIfAbsent(latestKey, () => []);
    samples.add(elapsed);
    if (samples.length > _rollingWindowSize) samples.removeAt(0);
    _lastSignalAt.remove(latestKey);
  }

  /// Rolling average time between [signal] firing and [type] actually being
  /// shown, or `null` if there's no sample yet.
  Duration? averageTimeToShow(String signal, AdSlotType type) {
    final samples = _timeToShow[_key(signal, type)];
    if (samples == null || samples.isEmpty) return null;
    final totalMs = samples.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return Duration(milliseconds: totalMs ~/ samples.length);
  }

  /// Call at a point in the host's user journey that typically precedes
  /// showing [type] (e.g. "level started"). Preloads immediately unless the
  /// rolling average time-to-show for this exact (signal, type) pair is
  /// already known to exceed [maxHoldDuration].
  void notifySignal(String signal, AdSlotType type) {
    final key = _key(signal, type);
    _lastSignalAt[key] = DateTime.now();

    final avg = averageTimeToShow(signal, type);
    if (avg != null && avg > maxHoldDuration) return;

    switch (type) {
      case AdSlotType.appOpen:
        AdManager().loadAppOpenAd();
      case AdSlotType.interstitial:
        AdManager().loadInterstitial();
      case AdSlotType.rewarded:
        AdManager().loadRewardedAd();
      case AdSlotType.rewardedInterstitial:
        AdManager().loadRewardedInterstitialAd();
      case AdSlotType.banner:
      case AdSlotType.mrec:
      case AdSlotType.native:
        // Per-widget-instance formats — no single global slot to prefetch.
        break;
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
