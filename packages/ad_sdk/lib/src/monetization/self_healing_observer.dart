import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../utils/ad_preferences.dart';
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
/// one provider per session (`AdConfig.provider`). Same as
/// [WaterfallTuner.recommendation] itself, "switching" only makes sense at
/// the NEXT session boundary — a host reads the emitted
/// [AdSelfHealingObserveEvent] (e.g. logs it to its own analytics, or
/// simply persists "recommended provider" for its next launch) and picks a
/// different `provider:` on its next `initialize()` call. No simultaneous
/// dual-adapter runtime is needed for that, and none is planned here —
/// this class only automates the "notice the recommendation" step, not the
/// "act on it" step, which stays a host decision.
///
/// **Round-31 audit — this used to be unable to ever fire on a real
/// device; T136 closed that.** The internal [WaterfallTuner] this wraps
/// only sees events for provider(s) a session actually requests ads from
/// — normally just one (see [WaterfallTuner]'s own doc comment). With
/// `AdManager().pickSessionProvider(...)` (T136) opted into at a low
/// exploration rate, some sessions genuinely run the alternate provider,
/// seeding real data for it over time — this observer can then actually
/// fire once enough of those sessions accumulate. Without opting into
/// T136's exploration, this observer is still effectively silent forever,
/// for the same reason as before — that has not changed, only the escape
/// hatch exists now.
class SelfHealingObserver {
  /// [persist] (default `true`, same reasoning as [WaterfallTuner]'s own
  /// flag) is what this class's dedupe actually needs now that its
  /// internal [_tuner]'s data survives across sessions: without ALSO
  /// persisting [_alreadyObserved], a recommendation that stays non-null
  /// for many sessions in a row would re-fire the exact same
  /// [AdSelfHealingObserveEvent] every single launch instead of once (a
  /// fresh in-memory dedupe set every session never remembers it already
  /// fired). Set to `false` to keep the original per-session-only dedupe.
  ///
  /// [reobserveAfter] (T163) — how long an identical (type, placement,
  /// recommendedProvider) key stays suppressed after firing once. See
  /// [_alreadyObserved]'s doc comment for why this exists at all.
  SelfHealingObserver({
    int rollingWindowSize = 20,
    bool persist = true,
    this.reobserveAfter = const Duration(days: 7),
    @visibleForTesting DateTime Function() debugClock = DateTime.now,
  })  : _tuner = WaterfallTuner(
            rollingWindowSize: rollingWindowSize, persist: persist),
        _persist = persist,
        _now = debugClock {
    _ready = _init();
  }

  final WaterfallTuner _tuner;
  final bool _persist;
  final DateTime Function() _now;
  final Duration reobserveAfter;
  StreamSubscription<AdEvent>? _sub;
  bool _disposed = false;

  // T136 (round 3 review, MAJOR) — same reasoning as
  // WaterfallTuner._init(): only start listening for events once the
  // persisted dedupe set has actually been hydrated, so a real
  // observation can't race ahead of it and then get silently clobbered.
  Future<void> _init() async {
    if (_persist) await _loadObserved();
    if (_disposed) return;
    _sub = AdManager().events.listen(_onEvent);
  }

  /// T136 (round 2 review, MAJOR) — same contract as
  /// [WaterfallTuner.ready]: completes once the persisted dedupe set has
  /// been loaded AND this instance has started listening for new events
  /// (or immediately for `persist: false`).
  Future<void> get ready => _ready;
  late final Future<void> _ready;

  /// T136 (round 2 review, MAJOR) — same reasoning as
  /// [WaterfallTuner._writeChain]: serializes persisted writes of
  /// [_alreadyObserved] so two observations landing close together can't
  /// race each other's `AdPreferences.getInstance()` and have the OLDER
  /// snapshot's write win.
  Future<void> _writeChain = Future.value();

  /// One observation per (type, placement, recommendedProvider) — once
  /// logged, a recommendation that keeps holding across later events (and,
  /// with [persist], later SESSIONS too) isn't re-reported every time. A
  /// DIFFERENT recommended provider for the same (type, placement) is a
  /// different key, so it still gets its own fresh notification.
  ///
  /// T163 — keyed to WHEN it last fired, not just whether it ever did.
  /// The original `Set<String>` version never forgot a key: once a
  /// (format, placement) pair had been recommended in BOTH directions
  /// (e.g. "switch to AppLovin", then later "switch to Google" once
  /// AppLovin cooled off), a genuine LATER need to recommend "switch to
  /// AppLovin" again — the exact same key as before — stayed silent
  /// forever, even though the underlying data had legitimately changed
  /// back. [reobserveAfter] bounds how long a key stays suppressed
  /// instead. Cleared implicitly on [dispose] when not persisting (a
  /// fresh instance starts with a clean slate); loaded from
  /// [AdPreferences] on construction when persisting.
  final Map<String, DateTime> _alreadyObserved = {};

  Future<void> _loadObserved() async {
    final prefs = await AdPreferences.getInstance();
    prefs.getSelfHealingObservedAt().forEach((key, millis) {
      _alreadyObserved[key] = DateTime.fromMillisecondsSinceEpoch(millis);
    });
  }

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
    final now = _now();
    final lastAt = _alreadyObserved[key];
    // codex re-review (P2) — `now.isBefore(lastAt)` (the device clock ran
    // backward since this key last fired — a real correction, e.g. an
    // NTP resync after a wrong manual clock setting) must NOT count as
    // "still fresh": a negative Duration compares as less than
    // [reobserveAfter] just like a small positive one would, so without
    // this guard a clock rollback recreates the exact silent-forever bug
    // this whole mechanism exists to fix, just via a different path.
    if (lastAt != null &&
        !now.isBefore(lastAt) &&
        now.difference(lastAt) < reobserveAfter) {
      return;
    }
    _alreadyObserved[key] = now;
    if (_persist) {
      final snapshot = _alreadyObserved
          .map((k, v) => MapEntry(k, v.millisecondsSinceEpoch));
      _writeChain = _writeChain.then((_) => AdPreferences.getInstance()
          .then((p) => p.setSelfHealingObservedAt(snapshot)));
    }
    AdManager().emitSelfHealingObservation(rec);
  }

  /// Stops listening immediately, then — same reasoning as
  /// [WaterfallTuner.dispose] — waits (bounded by [timeout]) for both this
  /// instance's own pending dedupe write AND the internal [_tuner]'s
  /// pending sample write to actually land before returning.
  Future<void> dispose({Duration timeout = const Duration(seconds: 2)}) async {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    final tunerDone = _tuner.dispose(timeout: timeout);
    if (_persist) {
      await _writeChain.timeout(timeout, onTimeout: () {});
    }
    await tunerDone;
  }
}
