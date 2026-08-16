import 'dart:async';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';
import '../utils/ad_preferences.dart';

/// Alert emitted on [FillRateBaselineMonitor.alerts] / read from
/// [FillRateBaselineMonitor.activeAlerts] when a slot's CURRENT SESSION fill
/// rate or average revenue-per-ad drops materially below its own on-device
/// 7-day baseline.
class FillRateRegressionAlert {
  const FillRateRegressionAlert({
    required this.type,
    required this.sessionFillRate,
    required this.baselineFillRate,
    required this.sessionAvgRevenueMicros,
    required this.baselineAvgRevenueMicros,
    required this.fillRateRegressed,
    required this.revenueRegressed,
  });

  final AdSlotType type;

  /// This session's fill rate (successes / load attempts) so far.
  final double sessionFillRate;

  /// Trailing 7-day fill rate baseline (EXCLUDING today — today is still the
  /// in-progress session being compared, not part of its own baseline).
  final double baselineFillRate;

  /// Average `AdRevenueEvent.valueMicros` per impression this session, or
  /// `null` if no revenue event has been observed yet this session.
  final int? sessionAvgRevenueMicros;

  /// Same, averaged over the trailing 7-day baseline. `null` if no revenue
  /// history exists yet (e.g. within the first week of install).
  final int? baselineAvgRevenueMicros;

  /// `true` if [sessionFillRate] dropped by at least the monitor's
  /// `regressionThreshold` fraction below [baselineFillRate].
  final bool fillRateRegressed;

  /// `true` if [sessionAvgRevenueMicros] dropped by at least
  /// `regressionThreshold` below [baselineAvgRevenueMicros]. Always `false`
  /// when either side has no revenue data.
  final bool revenueRegressed;
}

class _Tally {
  int attempts = 0;
  int successes = 0;
  int revenueMicros = 0;
  int revenueCount = 0;
}

/// T97 — Flagship: per-device fill-rate/eCPM regression detector.
///
/// Compares THIS SESSION's fill rate and average revenue-per-ad against a
/// rolling 7-calendar-day baseline persisted locally (`AdPreferences`) —
/// entirely on-device, no backend, no shadow ad requests. Surfaces
/// "interstitial fill rate is down 35% vs. this device's own 7-day
/// baseline" the moment enough session samples exist, via [alerts] (stream,
/// for reactive UI) and [activeAlerts] (snapshot, for `AdManager.diagnostics()`
/// / the debug overlay).
///
/// Deliberately compares a device against ITS OWN history, not a fleet-wide
/// average — consistent with the SDK's offline-first design elsewhere (VIP
/// Ed25519 signing, the client-side safety layer): no server, no aggregation
/// across users, works the same with zero connectivity.
///
/// Opt-in via `AdManager().enableFillRateBaselineMonitor(...)` — nothing is
/// persisted or tracked unless a host app calls that.
class FillRateBaselineMonitor {
  FillRateBaselineMonitor(
    this._prefs, {
    this.regressionThreshold = 0.2,
    this.minSamples = 5,
  })  : assert(regressionThreshold > 0 && regressionThreshold < 1,
            'regressionThreshold must be between 0 and 1 (exclusive)'),
        assert(minSamples > 0, 'minSamples must be positive') {
    _sub = AdManager().events.listen(_onEvent);
  }

  final AdPreferences _prefs;

  /// A session metric counts as "regressed" once it's at least this
  /// fraction below the 7-day baseline (default 0.2 = 20% worse).
  final double regressionThreshold;

  /// Minimum sample count required on BOTH sides (this session's tally, and
  /// the persisted baseline) before a comparison is trusted — guards
  /// against a single early failed load looking like a "100% drop".
  final int minSamples;

  final Map<AdSlotType, _Tally> _session = {};
  final Map<AdSlotType, FillRateRegressionAlert> _activeAlerts = {};

  /// Slots with a currently-active, already-emitted alert — suppresses
  /// repeat stream events while the regression persists (same convention as
  /// `FillRateMonitor._alerted`).
  final Set<AdSlotType> _alerted = {};

  final StreamController<FillRateRegressionAlert> _alertController =
      StreamController<FillRateRegressionAlert>.broadcast();

  /// Fires once per slot each time it newly regresses below baseline. Does
  /// not repeat while the regression persists — see [activeAlerts] for the
  /// current snapshot instead of relying on stream replay.
  Stream<FillRateRegressionAlert> get alerts => _alertController.stream;

  /// Current regression alerts, one per slot currently regressed — read this
  /// for a one-shot snapshot (e.g. the debug overlay), rather than the
  /// stream, since [alerts] does not replay past events to a late listener.
  Map<AdSlotType, FillRateRegressionAlert> get activeAlerts =>
      Map.unmodifiable(_activeAlerts);

  StreamSubscription<AdEvent>? _sub;

  void _onEvent(AdEvent event) {
    if (event is AdLoadEvent) {
      final tally = _session.putIfAbsent(event.type, () => _Tally());
      tally.attempts++;
      if (event.success) tally.successes++;
      unawaited(_prefs.recordFillRateBaselineSample(
        slotTypeName: event.type.name,
        attempts: 1,
        successes: event.success ? 1 : 0,
      ));
    } else if (event is AdRevenueEvent) {
      final tally = _session.putIfAbsent(event.type, () => _Tally());
      tally.revenueMicros += event.valueMicros;
      tally.revenueCount++;
      unawaited(_prefs.recordFillRateBaselineSample(
        slotTypeName: event.type.name,
        revenueMicros: event.valueMicros,
        revenueCount: 1,
      ));
    } else {
      return;
    }
    _checkRegression(event.type);
  }

  _Tally _baselineFor(AdSlotType type) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final history = _prefs.getFillRateBaselineHistory();
    final baseline = _Tally();
    history.forEach((date, perType) {
      if (date == today) return; // exclude the in-progress session's own day
      final counts = perType[type.name];
      if (counts == null) return;
      baseline.attempts += counts['attempts'] ?? 0;
      baseline.successes += counts['successes'] ?? 0;
      baseline.revenueMicros += counts['revenueMicros'] ?? 0;
      baseline.revenueCount += counts['revenueCount'] ?? 0;
    });
    return baseline;
  }

  void _checkRegression(AdSlotType type) {
    final session = _session[type];
    if (session == null || session.attempts < minSamples) {
      _clear(type);
      return;
    }
    final baseline = _baselineFor(type);
    if (baseline.attempts < minSamples) {
      // Not enough baseline history yet (e.g. first week of install) — a
      // real baseline is impossible to fabricate, so stay silent rather
      // than compare against noise.
      _clear(type);
      return;
    }

    final sessionFillRate = session.successes / session.attempts;
    final baselineFillRate = baseline.successes / baseline.attempts;
    final fillRateRegressed = baselineFillRate > 0 &&
        (baselineFillRate - sessionFillRate) / baselineFillRate >=
            regressionThreshold;

    final sessionAvgRevenue = session.revenueCount == 0
        ? null
        : session.revenueMicros ~/ session.revenueCount;
    final baselineAvgRevenue = baseline.revenueCount == 0
        ? null
        : baseline.revenueMicros ~/ baseline.revenueCount;
    final revenueRegressed = sessionAvgRevenue != null &&
        baselineAvgRevenue != null &&
        baselineAvgRevenue > 0 &&
        (baselineAvgRevenue - sessionAvgRevenue) / baselineAvgRevenue >=
            regressionThreshold;

    if (!fillRateRegressed && !revenueRegressed) {
      _clear(type);
      return;
    }

    final alert = FillRateRegressionAlert(
      type: type,
      sessionFillRate: sessionFillRate,
      baselineFillRate: baselineFillRate,
      sessionAvgRevenueMicros: sessionAvgRevenue,
      baselineAvgRevenueMicros: baselineAvgRevenue,
      fillRateRegressed: fillRateRegressed,
      revenueRegressed: revenueRegressed,
    );
    _activeAlerts[type] = alert;
    if (_alerted.add(type)) _alertController.add(alert);
  }

  void _clear(AdSlotType type) {
    _activeAlerts.remove(type);
    _alerted.remove(type);
  }

  /// Release the internal [AdManager().events] subscription and close
  /// [alerts]. Call this if you ever swap out or disable the monitor
  /// mid-session.
  void dispose() {
    _sub?.cancel();
    _alertController.close();
  }
}
