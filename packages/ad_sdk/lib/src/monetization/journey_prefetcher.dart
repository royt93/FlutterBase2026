import 'dart:async';

import 'package:flutter/foundation.dart';

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
  JourneyPrefetcher({
    this.maxHoldDuration = const Duration(minutes: 5),
    this.maxPendingSignalAge = const Duration(minutes: 5),
    @visibleForTesting DateTime Function() debugClock = DateTime.now,
  }) : _now = debugClock {
    _sub = AdManager().events.listen(_onEvent);
  }

  /// If the rolling average time-to-show for a (signal, type) pair would
  /// leave a preloaded ad sitting unused longer than this, [notifySignal]
  /// stops preloading eagerly for it — avoids holding a stale-feeling ad
  /// (and burning cap/impression budget) for a show that isn't imminent.
  final Duration maxHoldDuration;

  /// T133 — a DIFFERENT threshold from [maxHoldDuration], despite the
  /// similar-sounding names: this one guards a single pending signal
  /// against being matched to a show that comes long after it (the app
  /// was backgrounded for a long stretch, say) and having that huge gap
  /// recorded as a normal time-to-show sample — which would wrongly drag
  /// the rolling average up. [maxHoldDuration] instead reacts to that
  /// average AFTER it's already been computed from real, non-stale
  /// samples. Kept as a separate parameter (not reusing [maxHoldDuration])
  /// because a caller can legitimately configure a very short
  /// [maxHoldDuration] to test/tune preload-stop behavior without that
  /// also shrinking how old a pending signal is allowed to be before it's
  /// discarded outright — the two failure modes this class guards against
  /// are independent.
  final Duration maxPendingSignalAge;

  final DateTime Function() _now;

  final Map<String, DateTime> _lastSignalAt = {};

  /// Monotonically increasing per-key call order, used to break a genuine
  /// `DateTime` tie in [_onEvent] — [_now]'s resolution can return the same
  /// instant for two back-to-back [notifySignal] calls, and a tie must
  /// still resolve to whichever one actually fired last, not to whichever
  /// happens to iterate first in [_lastSignalAt].
  int _sequence = 0;
  final Map<String, int> _lastSignalSeq = {};
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
    int? latestSeq;
    for (final entry in _lastSignalAt.entries) {
      final parts = entry.key.split('|');
      if (parts.length != 2 || parts[1] != event.type.name) continue;
      // Compare by call-order sequence, not by DateTime — DateTime.now()'s
      // resolution can tie two back-to-back notifySignal() calls, and a tie
      // must still resolve to whichever one actually fired last.
      final seq = _lastSignalSeq[entry.key] ?? -1;
      if (latestSeq == null || seq > latestSeq) {
        latestAt = entry.value;
        latestSeq = seq;
        latestKey = entry.key;
      }
    }
    if (latestKey == null || latestAt == null) return;
    final elapsed = _now().difference(latestAt);
    _lastSignalAt.remove(latestKey);
    _lastSignalSeq.remove(latestKey);
    // T133 — a pending signal has no TTL otherwise: the app can be
    // backgrounded for a long stretch between notifySignal() and the next
    // matching show (which may be completely unrelated to the original
    // journey step), and that huge gap would get folded in as a normal
    // time-to-show sample, wrongly dragging the rolling average up (and
    // potentially disabling eager preload for a signal that's actually
    // fine). See maxPendingSignalAge's own doc comment for why this is a
    // separate threshold from maxHoldDuration, not a reuse of it.
    if (elapsed > maxPendingSignalAge) return;
    final samples = _timeToShow.putIfAbsent(latestKey, () => []);
    samples.add(elapsed);
    if (samples.length > _rollingWindowSize) samples.removeAt(0);
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
    _lastSignalAt[key] = _now();
    _lastSignalSeq[key] = _sequence++;

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
