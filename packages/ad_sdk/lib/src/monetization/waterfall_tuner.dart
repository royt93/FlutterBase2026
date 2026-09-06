import 'dart:async';
import 'dart:convert';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/ad_preferences.dart';

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
/// **Round-31 audit — real limitation, since closed by T136:** because a
/// single SESSION runs exactly one provider (`AdConfig.provider`),
/// [_loadResults] and [_revenueMicros] for the non-active provider stay
/// empty for any session that never requests ads from it — no code path
/// in this SDK ever shadow-requests the inactive provider to seed them
/// (that would burn a real ad request per format per session purely for
/// attribution, a cost/policy tradeoff this SDK deliberately does not
/// make). What DOES seed the other provider's data on a real device:
/// `AdManager().pickSessionProvider(...)` (T136) — a host that opts in
/// with a low `explorationRate` gets an occasional REAL session on the
/// alternate provider, with real [AdLoadEvent]/[AdRevenueEvent] for it.
/// Across enough of those sessions, [recommendation] can genuinely return
/// non-null on a single real device — not just across installs.
class WaterfallTuner {
  /// [persist] (default `true`) is what actually closes the "sits dead
  /// forever" gap noted in this class's own doc comment above — without
  /// it, every sample [_onEvent] records is lost the moment this instance
  /// is disposed (every `destroy()`, every real app process restart), so
  /// samples from occasional `pickSessionProvider` exploration sessions
  /// could never accumulate into anything [recommendation] could compare.
  /// Set to `false` only for a host that wants a purely in-memory,
  /// single-session tuner (e.g. tests, or a host with its own persistence).
  WaterfallTuner({int rollingWindowSize = 20, bool persist = true})
      : _rollingWindowSize = rollingWindowSize,
        _persist = persist {
    _ready = _init();
  }

  final int _rollingWindowSize;
  final bool _persist;

  final Map<_Key, List<bool>> _loadResults = {};
  final Map<_Key, List<int>> _revenueMicros = {};

  StreamSubscription<AdEvent>? _sub;

  // T136 (round 3 review, MAJOR) — the stream listener is only attached
  // AFTER hydration finishes, not from the constructor directly. A real
  // event arriving DURING the `await AdPreferences.getInstance()` gap
  // inside `_loadPersisted()` used to race it: `_onEvent` would add the
  // live sample first, then hydrate's `target[key] = ...` clobbered it
  // with the stale on-disk snapshot, silently losing that sample. Waiting
  // for hydrate before subscribing means no event can be processed before
  // this instance's in-memory state already reflects everything on disk.
  Future<void> _init() async {
    if (_persist) await _loadPersisted();
    // If dispose() already ran while this was still hydrating (a host
    // disposing immediately after construction, before ever awaiting
    // `ready`), don't attach a subscription an already-"disposed"
    // instance was never supposed to have.
    if (_disposed) return;
    _sub = AdManager().events.listen(_onEvent);
  }

  bool _disposed = false;

  /// T136 (round 2 review, MAJOR) — completes once the initial hydrate
  /// from [AdPreferences] finishes AND this instance has started
  /// listening for new events (or immediately, for `persist: false`). A
  /// host that wants a guarantee this instance already has whatever a
  /// PRIOR session persisted before calling [recommendation] can `await`
  /// this; [recommendation] itself doesn't wait for it (matches every
  /// other on-device signal in this SDK — no code here blocks a host on
  /// disk I/O), so a call made before [ready] completes may simply not
  /// see last session's data yet.
  Future<void> get ready => _ready;
  late final Future<void> _ready;

  /// T136 (round 2 review, MAJOR) — every persisted write is chained onto
  /// this instead of fired independently. Two overlapping
  /// `_savePersistedAsync()` calls (e.g. an [AdLoadEvent] and an
  /// [AdRevenueEvent] for the same ad landing back-to-back) each read the
  /// CURRENT in-memory maps and encode a full snapshot — with no
  /// serialization, whichever call's `await AdPreferences.getInstance()`
  /// happened to resolve last would win regardless of which snapshot was
  /// actually newer, the same class of bug T137's revision guard hit.
  /// Chaining onto one `Future` makes every write wait for the previous
  /// one to finish first, so they always land in the order they were
  /// queued.
  Future<void> _writeChain = Future.value();

  Future<void> _loadPersisted() async {
    final prefs = await AdPreferences.getInstance();
    final raw = prefs.getWaterfallTunerStateRaw();
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _hydrate<bool>(_loadResults, decoded['loadResults']);
      _hydrate<int>(_revenueMicros, decoded['revenueMicros']);
    } catch (_) {
      // Malformed/corrupt persisted state (or a format from a future SDK
      // version) — fail safe, start with empty history rather than
      // throwing or half-applying it. Same convention as
      // applyRemoteSafetyOverrides' fail-open parsing.
    }
  }

  void _hydrate<T>(Map<_Key, List<T>> target, dynamic raw) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final key = _Key.tryParse(entry.key.toString());
      final value = entry.value;
      if (key == null || value is! List) continue;
      // T136 (round 2 review, MAJOR) — re-apply the SAME rolling-window
      // bound hydrate is otherwise exempt from: a persisted blob from a
      // session configured with a LARGER rollingWindowSize (or a
      // corrupted/oversized value written some other way) must not make
      // this instance's history grow past what it is configured to keep
      // — `_onEvent` below only ever trims by one per new event, which
      // would take a very long time to shrink back down on its own.
      final values = value.whereType<T>().toList();
      target[key] = values.length > _rollingWindowSize
          ? values.sublist(values.length - _rollingWindowSize)
          : values;
    }
  }

  void _savePersisted() {
    if (!_persist) return;
    _writeChain = _writeChain.then((_) => _savePersistedAsync());
  }

  Future<void> _savePersistedAsync() async {
    final prefs = await AdPreferences.getInstance();
    final encoded = jsonEncode({
      'loadResults': {
        for (final e in _loadResults.entries) e.key.serialize(): e.value,
      },
      'revenueMicros': {
        for (final e in _revenueMicros.entries) e.key.serialize(): e.value,
      },
    });
    await prefs.setWaterfallTunerStateRaw(encoded);
  }

  void _onEvent(AdEvent event) {
    if (event is AdLoadEvent) {
      final key = _Key(event.providerTag, event.type, event.placement);
      final list = _loadResults.putIfAbsent(key, () => []);
      list.add(event.success);
      if (list.length > _rollingWindowSize) list.removeAt(0);
      _savePersisted();
    } else if (event is AdRevenueEvent) {
      final key = _Key(event.providerTag, event.type, event.placement);
      final list = _revenueMicros.putIfAbsent(key, () => []);
      list.add(event.valueMicros);
      if (list.length > _rollingWindowSize) list.removeAt(0);
      _savePersisted();
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

  /// Stops listening immediately (no new events recorded after this
  /// returns), then — T136 (round 2 review, MAJOR) — waits for any
  /// still-in-flight persisted write to actually land, up to [timeout],
  /// so a process teardown right after the last event doesn't silently
  /// lose it. Bounded rather than unbounded: a wedged SharedPreferences
  /// write must not hang whoever is disposing this (e.g. `AdManager
  /// .destroy()`) forever — same "wait a bit, then proceed anyway"
  /// convention as this SDK's other teardown paths.
  Future<void> dispose({Duration timeout = const Duration(seconds: 2)}) async {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    if (!_persist) return;
    await _writeChain.timeout(timeout, onTimeout: () {});
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

  // T136 — a null character separator, not '|', because `provider` and
  // `placement.id` are both host/SDK-controlled strings with no format
  // guarantee against containing '|' (an AdPlacement.custom id is
  // arbitrary host text); a raw control character is vanishingly unlikely
  // to collide in practice.
  static final String _sep = String.fromCharCode(0);

  String serialize() => '$provider$_sep${type.name}$_sep${placement.id}';

  static _Key? tryParse(String s) {
    final parts = s.split(_sep);
    if (parts.length != 3) return null;
    AdSlotType? type;
    for (final candidate in AdSlotType.values) {
      if (candidate.name == parts[1]) {
        type = candidate;
        break;
      }
    }
    if (type == null) return null;
    return _Key(parts[0], type, AdPlacement.custom(parts[2]));
  }
}
