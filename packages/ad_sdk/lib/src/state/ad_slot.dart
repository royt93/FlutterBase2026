import 'package:flutter/foundation.dart';

import 'backoff.dart';

/// Logical type of ad slot (one of the four ad placements supported by both
/// AdMob and AppLovin MAX).
enum AdSlotType {
  appOpen,
  interstitial,
  rewarded,
  banner,
}

/// Lifecycle states a single ad slot can be in.
///
/// Transitions:
/// ```
///   idle    → loading                (loadX called)
///   loading → ready    | cooldown    (load callback success/fail)
///   ready   → showing  | idle        (show called / expired)
///   showing → idle     | cooldown    (dismiss / display fail)
///   cooldown→ idle                   (after backoff window elapses)
/// ```
enum AdSlotState {
  idle,
  loading,
  ready,
  showing,
  cooldown,
}

/// Per-slot mutable state holder. Replaces the ~14 hand-managed bool flags
/// (`_isInterLoading`, `_isMaxInterReady`, `_lastInterErrorTime`, ...) that
/// caused most of the historical Fix #N race-conditions.
///
/// Wraps a [ValueNotifier] so widgets can react without a state-management
/// library and without `setState`.
class AdSlot {
  AdSlot({required this.type});

  /// Logical type of this slot.
  final AdSlotType type;

  /// Reactive state — listenable from widgets.
  final ValueNotifier<AdSlotState> state =
      ValueNotifier<AdSlotState>(AdSlotState.idle);

  /// Time of the most recent failed load (or show), used for cooldown checks.
  /// Null when no error has been seen.
  DateTime? lastErrorAt;

  /// Time of the most recent successful load, used for ad-expiry (AdMob
  /// app-open ads expire after 4 hours).
  DateTime? lastLoadedAt;

  /// Number of consecutive load failures — used by the exponential backoff
  /// strategy.
  int consecutiveFailures = 0;

  /// Pending one-shot callback fired when an in-flight load/show completes.
  /// Always cleared after firing; [AdManager.destroy] flushes it with `false`.
  void Function(bool result)? pendingCallback;

  // ─── Convenience reads ─────────────────────────────────────────────────────

  AdSlotState get value => state.value;
  bool get isIdle => value == AdSlotState.idle;
  bool get isLoading => value == AdSlotState.loading;
  bool get isReady => value == AdSlotState.ready;
  bool get isShowing => value == AdSlotState.showing;
  bool get isCooldown => value == AdSlotState.cooldown;

  /// Default backoff used when [beginLoad] is called without one. Adapter
  /// initialisation can override this from `AdConfig`.
  static const Backoff defaultBackoff = Backoff();

  // ─── Transitions ───────────────────────────────────────────────────────────

  /// Move slot into [AdSlotState.loading]. Returns `false` if:
  ///   - already loading or showing, OR
  ///   - in cooldown and the [backoff] window has not yet elapsed.
  ///
  /// The [backoff] check replaces the legacy fixed 15-min cooldown — without
  /// it, repeated failures would re-fire load every retry tick.
  bool beginLoad({Backoff backoff = defaultBackoff}) {
    if (isLoading || isShowing) return false;
    if (isCooldown &&
        backoff.isInCooldown(
          lastErrorAt: lastErrorAt,
          consecutiveFailures: consecutiveFailures,
        )) {
      return false;
    }
    state.value = AdSlotState.loading;
    return true;
  }

  /// Mark load successful: slot becomes [AdSlotState.ready].
  void markReady() {
    lastLoadedAt = DateTime.now();
    consecutiveFailures = 0;
    state.value = AdSlotState.ready;
    _firePending(true);
  }

  /// Mark load failed: slot becomes [AdSlotState.cooldown] (caller decides
  /// when to allow retry — see [isCooldownActive]).
  void markFailed() {
    lastErrorAt = DateTime.now();
    consecutiveFailures++;
    state.value = AdSlotState.cooldown;
    _firePending(false);
  }

  /// Helper that fires + clears [pendingCallback], swallowing any throw.
  /// Without this, a buggy caller-supplied callback could crash the native
  /// listener thread.
  void _firePending(bool result) {
    final cb = pendingCallback;
    pendingCallback = null;
    if (cb == null) return;
    try {
      cb(result);
    } catch (_) {
      // Swallow — caller logging is their responsibility; crashing the
      // adapter's listener thread benefits nobody.
    }
  }

  /// Move slot into [AdSlotState.showing]. Only valid from [AdSlotState.ready].
  bool beginShow() {
    if (!isReady) return false;
    state.value = AdSlotState.showing;
    return true;
  }

  /// Slot was shown then dismissed. Returns to [AdSlotState.idle] (caller
  /// usually triggers a fresh load right after).
  void markDismissed() {
    state.value = AdSlotState.idle;
  }

  /// Show failed mid-flight. Returns to [AdSlotState.cooldown].
  void markShowFailed() {
    lastErrorAt = DateTime.now();
    consecutiveFailures++;
    state.value = AdSlotState.cooldown;
  }

  /// Whether this slot is still in cooldown (has not waited [cooldownMs]
  /// since [lastErrorAt]).
  bool isCooldownActive(int cooldownMs) {
    final t = lastErrorAt;
    if (t == null) return false;
    return DateTime.now().difference(t).inMilliseconds < cooldownMs;
  }

  /// Reset to [AdSlotState.idle] and clear timestamps. Used by [AdManager.destroy].
  void reset() {
    state.value = AdSlotState.idle;
    lastErrorAt = null;
    lastLoadedAt = null;
    consecutiveFailures = 0;
    _firePending(false);
  }

  @override
  String toString() => 'AdSlot($type, ${value.name}, fails=$consecutiveFailures)';
}
