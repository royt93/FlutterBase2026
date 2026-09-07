import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';

/// T145 — "Cross-provider Revenue Integrity Ledger".
///
/// **This is a time-window HEURISTIC, not exact reconciliation.** Neither
/// [AdShowEvent] nor [AdRevenueEvent] carries a shared request/impression
/// ID (verified directly against `ad_event.dart` — both only carry
/// `providerTag`, `type`, `placement`), so there is no way to prove a
/// specific show and a specific revenue callback are "the same impression".
/// What this DOES do: for every successful show, expect a same-
/// `(providerTag, placement)` [AdRevenueEvent] within [matchWindow]. A show
/// with none is flagged as a **possible** revenue-integrity issue — most
/// often simply a revenue callback arriving later than [matchWindow] (a
/// slow network, a mediation SDK quirk), not proof of fraud or a lost
/// impression. Read [AdManager.incidentRecorder]'s own entries (or a
/// host's own listener on it) as a signal to investigate, not a verdict.
///
/// Completely on-device: only consumes events this SDK already emits from
/// AdMob/AppLovin — no third-party API calls, no backend.
///
/// **Known limitation (round-1 review) — purely event-driven, no internal
/// [Timer].** [matchWindow] is only actually evaluated the next time ANY
/// [AdEvent] arrives (any type, any provider, any placement) — expiry is a
/// side effect of processing an event, not a scheduled check. If the app
/// goes quiet (no ad activity at all) right after a show that never gets
/// its revenue callback, that pending entry sits un-flagged in memory
/// until the next event of any kind arrives, however long that takes — or
/// until [dispose] silently drops it. This trades a small, bounded memory
/// footprint and zero extra timers for delayed-rather-than-missed
/// detection; it does not affect correctness once another event does
/// arrive, and a genuinely idle app has no ad revenue to audit anyway.
class RevenueIntegrityLedger {
  RevenueIntegrityLedger({
    this.matchWindow = const Duration(seconds: 60),
    @visibleForTesting DateTime Function() debugClock = DateTime.now,
  }) : _now = debugClock {
    _sub = AdManager().events.listen(_onEvent);
  }

  /// How long a successful show waits for a matching [AdRevenueEvent]
  /// before being flagged. Configurable on purpose — too short trips on
  /// perfectly normal late revenue callbacks; too long delays detection of
  /// a real gap. No single default suits every mediation setup; tune
  /// against real on-device data for the specific app before relying on
  /// the default.
  final Duration matchWindow;

  final DateTime Function() _now;
  StreamSubscription<AdEvent>? _sub;

  final List<_PendingShow> _pending = [];

  /// Diagnostic: how many successful shows are currently waiting on a
  /// matching revenue event.
  int get pendingCount => _pending.length;

  void _onEvent(AdEvent event) {
    _sweepExpired();
    if (event is AdShowEvent) {
      if (!event.success) return;
      _pending.add(_PendingShow(
        providerTag: event.providerTag,
        placement: event.placement,
        at: _now(),
      ));
      return;
    }
    if (event is AdRevenueEvent) {
      // FIFO: no shared ID exists, so the OLDEST still-pending show for
      // this (providerTag, placement) is the best-effort match — matches
      // the order revenue callbacks almost always arrive in for a given
      // key, and avoids an arbitrary/unstable match choice.
      final index = _pending.indexWhere((p) =>
          p.providerTag == event.providerTag &&
          p.placement == event.placement);
      if (index != -1) _pending.removeAt(index);
    }
  }

  void _sweepExpired() {
    final now = _now();
    _pending.removeWhere((p) {
      if (now.difference(p.at) <= matchWindow) return false;
      AdManager().incidentRecorder.record(
        'revenue_integrity_missing:${p.providerTag}:${p.placement.id}',
        AdManager().stateSnapshot.value,
        now: now,
      );
      return true;
    });
  }

  /// Stops listening for new events. Already-pending entries are dropped
  /// without being flagged — a host disposing this mid-session (e.g.
  /// `AdManager().destroy()`) isn't reporting a real integrity gap, just
  /// tearing down.
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _pending.clear();
  }
}

class _PendingShow {
  const _PendingShow({
    required this.providerTag,
    required this.placement,
    required this.at,
  });

  final String providerTag;
  final AdPlacement placement;
  final DateTime at;
}
