import 'dart:async';

import '../config/ad_config.dart';
import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';

/// Maps an [AdLoadEvent.providerTag] (`'[AdMob]'`/`'[AppLovin]'`) back to
/// the [AdProvider] it came from — `null` for anything else (e.g. a test
/// fake's `'[Fake]'` tag), since [AdConfig] has no such provider to pick.
AdProvider? _providerForTag(String? tag) => switch (tag) {
      '[AdMob]' => AdProvider.admob,
      '[AppLovin]' => AdProvider.appLovin,
      _ => null,
    };

enum ProviderCircuitState { closed, open, halfOpen }

/// T143 — "Zero-shadow dual-provider failover", reduced scope (the SDK
/// still serves exactly one provider per session by design — see
/// `AdConfig.provider` — a full concurrent dual-adapter runtime is a much
/// bigger architectural change, deliberately out of scope here).
///
/// Deliberately NOT [WaterfallTuner]'s fill-rate×eCPM comparison — that
/// needs real accumulated data for BOTH providers (via
/// `AdManager().pickSessionProvider(...)` exploration sessions), which is
/// slow to build up and is a *quality* signal, not a *reliability* one.
/// This tracks a much simpler, purely CURRENT-provider signal instead:
/// [consecutiveFailureThreshold] consecutive [AdLoadEvent] failures in a
/// row (any format, no successful load in between) — recommend the OTHER
/// provider for the host's NEXT `initialize()` call. "Zero shadow
/// requests": the recommendation never needs any data for the provider it
/// recommends switching TO, unlike [WaterfallTuner.recommendation].
///
/// Same architecture constraint as every other T1xx tuning class in this
/// package ([WaterfallTuner], [SelfHealingObserver]): this NEVER switches
/// anything itself, only recommends — see [AdManager.applyProviderFailover]
/// for how a host applies that recommendation to its own provider choice.
///
/// Completely opt-in via `AdManager().enableProviderFailoverAdvisor(...)` —
/// nothing is tracked unless a host app calls that.
class ProviderFailoverAdvisor {
  static const _tag = 'ProviderFailoverAdvisor';
  static const _defaultConsecutiveFailureThreshold = 5;

  /// [persist] (default `true`) is what makes this class's whole purpose
  /// possible: the failing session and the host reading
  /// [shouldFailoverNextSession] are, by definition, two different app
  /// processes (this session failed repeatedly; the NEXT `initialize()`
  /// call — likely after an app restart — is where the recommendation
  /// actually gets used). Without persistence the streak would always
  /// read back as 0 on the very call site that needs it. Set to `false`
  /// only for a purely in-memory, single-session use (e.g. tests).
  ProviderFailoverAdvisor({
    int consecutiveFailureThreshold = _defaultConsecutiveFailureThreshold,
    bool persist = true,
    this.cooldown = const Duration(minutes: 5),
    DateTime Function()? now,
  })  : consecutiveFailureThreshold =
            _validThreshold(consecutiveFailureThreshold),
        _persist = persist,
        _now = now ?? DateTime.now {
    if (cooldown <= Duration.zero) {
      throw ArgumentError.value(cooldown, 'cooldown', 'must be positive');
    }
    _ready = _init();
  }

  /// T171 — a value `<= 0` would make [shouldFailoverNextSession] read
  /// `true` (`_consecutiveFailures >= threshold`, and `_consecutiveFailures`
  /// starts at 0) before a single real failure ever happened — a
  /// misconfigured host would get an immediate, silent failover
  /// recommendation with no failures behind it. Substituting the default
  /// rather than throwing/asserting keeps a dev's config typo from crashing
  /// the app in ANY build mode, debug included — a thrown assert here would
  /// take down the whole app over a config mistake this class can recover
  /// from on its own.
  static int _validThreshold(int value) {
    if (value <= 0) {
      SafeLogger.w(
          _tag,
          'consecutiveFailureThreshold=$value is <= 0 (would recommend '
          'failover immediately, with zero real failures) — using default '
          '$_defaultConsecutiveFailureThreshold instead');
      return _defaultConsecutiveFailureThreshold;
    }
    return value;
  }

  /// Below this many consecutive load failures, [shouldFailoverNextSession]
  /// stays `false` — a genuinely intermittent failure pattern (occasional
  /// misses mixed with successes) never trips this, only an unbroken run
  /// of failures does.
  final int consecutiveFailureThreshold;

  final bool _persist;
  final Duration cooldown;
  final DateTime Function() _now;

  int _consecutiveFailures = 0;

  /// Which provider tag the current streak belongs to — a real provider
  /// switch (a different tag on the next event) resets the streak instead
  /// of letting the OLD provider's near-threshold count carry over onto
  /// whichever provider is now actually active.
  String? _lastProviderTag;
  DateTime? _openedAt;
  bool _probeClaimed = false;

  bool _disposed = false;
  StreamSubscription<AdEvent>? _sub;

  // T136-style hydrate-before-listen ordering (same race this package's
  // other persisted tuners already fixed): a real event arriving during
  // the `await AdPreferences.getInstance()` gap inside `_loadPersisted()`
  // must not race ahead of hydration and get silently clobbered by it.
  Future<void> _init() async {
    if (_persist) await _loadPersisted();
    if (_disposed) return;
    _sub = AdManager().events.listen(_onEvent);
  }

  Future<void> _loadPersisted() async {
    final prefs = await AdPreferences.getInstance();
    _consecutiveFailures = prefs.getProviderFailoverConsecutiveFailures();
    _lastProviderTag = prefs.getProviderFailoverLastProviderTag();
  }

  /// Completes once the persisted streak has been hydrated AND this
  /// instance has started listening for new events (or immediately for
  /// `persist: false`).
  Future<void> get ready => _ready;
  late final Future<void> _ready;

  // Same write-serialization reasoning as WaterfallTuner/SelfHealingObserver
  // — two events landing close together must not race each other's
  // AdPreferences.getInstance() and have the older snapshot's write win.
  Future<void> _writeChain = Future.value();

  void _onEvent(AdEvent event) {
    if (event is! AdLoadEvent) return;
    // Round-49 audit fix (MINOR) — a load that fails purely because the
    // device is offline says nothing about THIS provider's quality (the
    // other provider would fail identically), so it must not count toward
    // a "switch providers" recommendation. The offline pre-check already
    // emits `AdSkipEvent` instead of this, but a load that starts while
    // connected and loses the network mid-flight still surfaces here as
    // `AdLoadEvent(success:false)` with nothing else distinguishing it
    // from a real provider failure — e.g. a flappy connection during a
    // reconnect-debounce refill could otherwise run 5 such loads back to
    // back and trip a false failover recommendation.
    if (!event.success && !AdManager().isConnected) return;
    if (_lastProviderTag != event.providerTag) {
      _lastProviderTag = event.providerTag;
      _consecutiveFailures = 0;
    }
    if (event.success) {
      _consecutiveFailures = 0;
      _openedAt = null;
      _probeClaimed = false;
    } else {
      _consecutiveFailures++;
      if (_consecutiveFailures >= consecutiveFailureThreshold) {
        if (circuitState == ProviderCircuitState.halfOpen) {
          _openedAt = _now();
          _probeClaimed = false;
        } else {
          _openedAt ??= _now();
        }
      }
    }
    if (!_persist) return;
    _writeChain = _writeChain.then((_) async {
      final prefs = await AdPreferences.getInstance();
      await prefs.setProviderFailoverConsecutiveFailures(_consecutiveFailures);
      await prefs.setProviderFailoverLastProviderTag(_lastProviderTag);
    });
  }

  /// `true` once [consecutiveFailureThreshold] consecutive load failures
  /// have been observed for the current provider with no successful load
  /// in between — a host checking this before its NEXT `initialize()`
  /// call should pick the other provider instead (see
  /// [AdManager.applyProviderFailover]).
  bool get shouldFailoverNextSession =>
      circuitState == ProviderCircuitState.open;

  ProviderCircuitState get circuitState {
    final opened = _openedAt;
    if (opened == null) return ProviderCircuitState.closed;
    if (_now().difference(opened) >= cooldown) {
      return ProviderCircuitState.halfOpen;
    }
    return ProviderCircuitState.open;
  }

  bool allowHalfOpenProbe() {
    if (circuitState != ProviderCircuitState.halfOpen || _probeClaimed) {
      return false;
    }
    _probeClaimed = true;
    return true;
  }

  /// The specific [AdProvider] whose consecutive failures actually tripped
  /// [shouldFailoverNextSession] — `null` when it's `false`, or when the
  /// tripped streak's provider tag doesn't map to a real [AdProvider] (a
  /// test fake's tag, say).
  ///
  /// Round-1 independent review (MAJOR) — [AdManager.applyProviderFailover]
  /// used to flip WHATEVER provider its caller passed in whenever
  /// [shouldFailoverNextSession] was `true`, with no check that the
  /// passed-in candidate was actually the provider that failed. If a
  /// host's OTHER provider-selection logic (`pickProviderCohort`/
  /// `pickSessionProvider`) had already independently picked the OTHER
  /// (healthy) provider for next session, applying failover on top of
  /// that flipped it straight back to the one that just failed. Exposing
  /// the actual failing provider lets the caller only act when its
  /// candidate matches it.
  AdProvider? get failingProvider =>
      shouldFailoverNextSession ? _providerForTag(_lastProviderTag) : null;

  /// Audit fix (post-T208) — the provider [circuitState] is currently
  /// tracking whenever that state is anything other than
  /// [ProviderCircuitState.closed] (`open` OR `halfOpen`), unlike
  /// [failingProvider] above, which only reports it during `open`.
  ///
  /// [AdManager.applyProviderFailover] needs this: the pre-fix version
  /// checked `failingProvider` alone, which is `null` throughout the whole
  /// `halfOpen` window — every call during that window silently read as
  /// "provider is healthy, do nothing", reverting straight back to the
  /// previously-failing provider with NO real verification it recovered,
  /// and with [allowHalfOpenProbe]'s single-claim guard never even
  /// consulted (dead code — nothing gated on it). This getter lets that
  /// call site tell `open` and `halfOpen` apart and route `halfOpen`
  /// through [allowHalfOpenProbe] instead.
  AdProvider? get circuitTrackedProvider =>
      circuitState == ProviderCircuitState.closed
          ? null
          : _providerForTag(_lastProviderTag);

  /// Stops listening immediately, then waits (bounded by [timeout]) for
  /// any still-in-flight persisted write to actually land — same
  /// "wait a bit, then proceed anyway" convention as this package's other
  /// persisted tuners.
  Future<void> dispose({Duration timeout = const Duration(seconds: 2)}) async {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    if (!_persist) return;
    await _writeChain.timeout(timeout, onTimeout: () {});
  }
}
