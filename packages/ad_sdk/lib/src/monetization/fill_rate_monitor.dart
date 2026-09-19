import 'dart:async';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';

/// Alert emitted on [FillRateMonitor.alerts] when a slot's trailing fill rate
/// drops below [FillRateMonitor.lowFillRateThreshold].
class FillRateAlert {
  const FillRateAlert({
    required this.type,
    required this.fillRate,
    required this.threshold,
  });

  final AdSlotType type;
  final double fillRate;
  final double threshold;
}

/// Opt-in fill-rate monitor — v1.
///
/// Watches `AdManager().events` for [AdLoadEvent]s and tracks a trailing
/// success rate per [AdSlotType] for the currently-active provider. This is
/// deliberately simpler than a "shadow eCPM comparison" against a second,
/// non-active provider: it never issues extra ad requests (no added policy
/// risk or wasted quota), it just watches the load results the SDK already
/// produces and flags an abnormal drop.
///
/// Emits one [FillRateAlert] the first time a slot's rate drops below
/// [lowFillRateThreshold] within a full trailing window, then stays silent
/// until the rate recovers back above threshold (so it can alert again on a
/// later dip, without spamming every event while the drop persists).
///
/// Completely opt-in via `AdManager().enableFillRateMonitor(...)` — nothing
/// is tracked unless a host app calls that.
class FillRateMonitor {
  FillRateMonitor({
    this.lowFillRateThreshold = 0.3, // below 30% is considered abnormal.
    int rollingWindowSize = 20,
  }) : _rollingWindowSize = rollingWindowSize {
    // T197 — a real runtime check, not just `assert` (compiled out of
    // release builds): a misconfigured threshold/window here doesn't
    // crash anything downstream — the monitor just silently never alerts
    // (or spams every load) for the rest of the app's life in
    // production, with no signal to the host that anything is wrong.
    // Throwing here beats clamping the value into range: clamping would
    // hide the bug behind a value the host never actually asked for.
    if (lowFillRateThreshold <= 0 || lowFillRateThreshold >= 1) {
      throw ArgumentError.value(
          lowFillRateThreshold,
          'lowFillRateThreshold',
          'must be between 0 and 1 (exclusive) — a value near 1.0 alerts '
              'on almost every load, near 0.0 never alerts at all');
    }
    if (rollingWindowSize <= 0) {
      throw ArgumentError.value(rollingWindowSize, 'rollingWindowSize',
          'must be positive — a zero or negative window can never fill');
    }
    _sub = AdManager().events.listen(_onEvent);
  }

  /// Below this trailing fill rate (fraction of load attempts that
  /// succeeded), a slot is considered abnormal and triggers an alert.
  final double lowFillRateThreshold;
  final int _rollingWindowSize;

  /// Trailing load results (true = success), most-recent last, per slot.
  final Map<AdSlotType, List<bool>> _loadResults = {};

  /// Slots currently below threshold — suppresses repeat alerts until the
  /// rate recovers.
  final Set<AdSlotType> _alerted = {};

  final StreamController<FillRateAlert> _alertController =
      StreamController<FillRateAlert>.broadcast();

  /// Fires once per slot each time its fill rate newly drops below
  /// [lowFillRateThreshold]. Does not repeat while the drop persists.
  Stream<FillRateAlert> get alerts => _alertController.stream;

  StreamSubscription<AdEvent>? _sub;

  void _onEvent(AdEvent event) {
    if (event is! AdLoadEvent) return;
    // Round-49 audit fix (MINOR) — same reasoning as
    // ProviderFailoverAdvisor's identical guard: a load that fails purely
    // because the device is offline says nothing about this provider's
    // fill rate, and would otherwise drag the trailing rate down (and
    // could trigger a false alert) during a network flap.
    if (!event.success && !AdManager().isConnected) return;
    final list = _loadResults.putIfAbsent(event.type, () => []);
    list.add(event.success);
    // ponytail: simple List truncation, no ring buffer — 20 bools is nothing.
    if (list.length > _rollingWindowSize) {
      list.removeAt(0);
    }

    final rate = fillRate(event.type);
    if (list.length >= _rollingWindowSize && rate < lowFillRateThreshold) {
      if (_alerted.add(event.type)) {
        _alertController.add(FillRateAlert(
          type: event.type,
          fillRate: rate,
          threshold: lowFillRateThreshold,
        ));
      }
    } else {
      _alerted.remove(event.type);
    }
  }

  /// Trailing fill rate for [type] — fraction of the last (up to)
  /// [rollingWindowSize] load attempts that succeeded. `1.0` if no load
  /// attempts have been observed yet for this slot (nothing abnormal to
  /// report absent data).
  double fillRate(AdSlotType type) {
    final list = _loadResults[type];
    if (list == null || list.isEmpty) return 1.0;
    return list.where((v) => v).length / list.length;
  }

  /// Release the internal [AdManager().events] subscription and close
  /// [alerts]. Call this if you ever swap out or disable the monitor
  /// mid-session.
  void dispose() {
    _sub?.cancel();
    _alertController.close();
  }
}
