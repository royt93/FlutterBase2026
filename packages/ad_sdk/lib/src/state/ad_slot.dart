import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/safe_logger.dart';
import 'backoff.dart';

/// Logical type of ad slot (one of the four ad placements supported by both
/// AdMob and AppLovin MAX).
enum AdSlotType {
  appOpen,
  interstitial,
  rewarded,
  banner,
  mrec,
  native,
  // T89 — AdMob only (Google's "Rewarded Interstitial" format: shown at a
  // natural transition point, not behind an explicit "watch ad" tap).
  // AppLovin MAX has no equivalent ad unit type — its adapter never
  // transitions this slot out of idle. See AdManager's
  // loadRewardedInterstitialAd/showRewardedInterstitialAd doc comments.
  rewardedInterstitial,
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

  /// Begin a load that BYPASSES the cooldown backoff window.
  ///
  /// Used to immediately refill a slot after a *show* failure (or any case
  /// where the ad object was spent but the load path itself is healthy). After
  /// [markShowFailed]/[markFailed] the slot is in [AdSlotState.cooldown] with
  /// `lastErrorAt = now`, so a plain [beginLoad] would be blocked by its own
  /// just-recorded error and the slot would stay empty until the periodic retry
  /// timer fires minutes later. The backoff exists to throttle *flapping loads*
  /// — it must not strand a slot whose only failure was a one-off display miss.
  ///
  /// Genuine repeated *load* failures are still throttled because each load
  /// goes through [markFailed] and callers use [beginLoad] for the retry path.
  bool beginReload() {
    if (isLoading || isShowing) return false;
    state.value = AdSlotState.loading;
    return true;
  }

  /// Forces this slot back out of `loading` after [timeout] if the native
  /// SDK never calls back (neither [beginLoad] nor [beginReload] has any
  /// internal timeout of its own — without this, a callback that never
  /// arrives leaves the slot stuck in `loading` forever, since every later
  /// `beginLoad`/`beginReload` call is a no-op while already loading).
  ///
  /// `AdManager`'s own `loadX()` methods already arm one of these
  /// automatically. Call this directly ONLY from a load that intentionally
  /// bypasses `AdManager`'s path — e.g. an adapter's internal
  /// reload-after-show-failure, which calls the native SDK directly to skip
  /// the cooldown backoff `AdManager.loadX()` would otherwise apply, but
  /// must still not be allowed to hang forever if that reload's own
  /// callback never fires either (2026-08-16 audit finding).
  /// [onTimeout] runs immediately before `markFailed()` when the deadline is
  /// hit. M3 (independent review): moving the slot to `cooldown` is not enough
  /// on its own for the widget-backed formats — the adapter also caches the
  /// dead ad object per key and early-returns on it, so without a hook to
  /// clear that cache the slot state change repaired nothing.
  void armLoadWatchdog(String label, Duration timeout,
      {void Function()? onTimeout}) {
    if (!isLoading) return;
    // 2026-08-17 fork-review audit: cancel any watchdog still pending from an
    // earlier arm on this slot — otherwise a stale timer from a load that
    // already moved on (e.g. this same reload path re-arming its own
    // watchdog before the previous one's deadline) fires markFailed()
    // against the NEW loading window early.
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(timeout, () {
      if (!isLoading) return;
      SafeLogger.w(
          'AdSlot',
          '⏱️ $label load watchdog fired after ${timeout.inSeconds}s — no '
          'native callback, forcing markFailed()');
      try {
        onTimeout?.call();
      } catch (e) {
        SafeLogger.w('AdSlot', '$label watchdog onTimeout threw: $e');
      }
      markFailed();
    });
  }

  Timer? _watchdogTimer;

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

  /// How long [beginShow] waits for the native SDK to confirm the ad actually
  /// reached the screen before deciding the show request was swallowed.
  ///
  /// 10s is far longer than any real display latency (AppLovin reports
  /// `onAdDisplayed` and GMA `onAdShowedFullScreenContent` within
  /// milliseconds of the ad appearing — the waterfall work all happens during
  /// *load*), and this window closes the moment [markDisplayed] is called.
  static const Duration showConfirmTimeout = Duration(seconds: 10);

  Timer? _showConfirmTimer;

  /// Move the slot into [AdSlotState.showing]. Only valid from
  /// [AdSlotState.ready].
  ///
  /// [onShowNeverConfirmed] arms a watchdog for the gap between "we asked the
  /// native SDK to show this ad" and "the SDK told us it is on screen".
  /// Round-7 audit, MAJOR: both `show*` paths hand the request to a
  /// fire-and-forget native call and then wait for a callback. When the SDK
  /// swallows the request — AppLovin's `showAd()` on an ad its own cache has
  /// since expired is a documented no-op, and a GMA ad whose activity dies
  /// during presentation is the same class of failure — NO callback of any
  /// kind arrives. The slot then sits in `showing` for the rest of the
  /// session: both [beginLoad] and [beginReload] refuse while `isShowing`, so
  /// the format never loads again, and the caller awaiting the show result
  /// never resolves either. One wedged interstitial meant zero interstitials
  /// until the user restarted the app.
  ///
  /// This deliberately does NOT guard the *rest* of the showing state. Once
  /// [markDisplayed] has confirmed the ad is on screen, the slot may stay
  /// `showing` for as long as the user leaves it there — a rewarded ad the
  /// user pauses, or an iOS ad still presented while the app is backgrounded
  /// after a click-out to the App Store. A timer that force-released the slot
  /// there would tear down a live ad and could stack a second full-screen on
  /// top of it, which is worse than the hang it would fix. The residual
  /// "displayed, then the dismiss callback was lost" case is left to the
  /// App Open path's own lifecycle-aware watchdog, the only surface where a
  /// foreground signal reliably means the overlay is gone.
  bool beginShow({void Function()? onShowNeverConfirmed}) {
    if (!isReady) return false;
    state.value = AdSlotState.showing;
    _showConfirmTimer?.cancel();
    _showConfirmTimer = null;
    if (onShowNeverConfirmed == null) return true;
    _showConfirmTimer = Timer(showConfirmTimeout, () {
      _showConfirmTimer = null;
      // A normal display confirmation (or an early dismiss/failure) already
      // moved the slot on — nothing to recover.
      if (!isShowing) return;
      SafeLogger.e(
          'AdSlot',
          '$type: the native SDK never confirmed the ad reached the screen '
              '${showConfirmTimeout.inSeconds}s after show() — treating the '
              'request as swallowed and releasing the slot');
      try {
        onShowNeverConfirmed();
      } catch (e) {
        SafeLogger.w('AdSlot', '$type onShowNeverConfirmed threw: $e');
      }
      markShowFailed();
    });
    return true;
  }

  /// The native SDK confirmed the ad is on screen. Disarms [beginShow]'s
  /// watchdog — see its doc comment for why nothing may fire after this.
  void markDisplayed() {
    _showConfirmTimer?.cancel();
    _showConfirmTimer = null;
  }

  /// Slot was shown then dismissed. Returns to [AdSlotState.idle] (caller
  /// usually triggers a fresh load right after).
  void markDismissed() {
    _showConfirmTimer?.cancel();
    _showConfirmTimer = null;
    state.value = AdSlotState.idle;
  }

  /// Show failed mid-flight. Returns to [AdSlotState.cooldown].
  void markShowFailed() {
    _showConfirmTimer?.cancel();
    _showConfirmTimer = null;
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
    // Round-7 audit, MINOR: reset() left the load watchdog armed, so a timer
    // that outlived the load it belonged to landed `markFailed()` on the NEXT
    // load window — stamping `lastErrorAt` and arming a backoff against a load
    // that never failed. The show watchdog is cancelled here for the same
    // reason (reset() means "this slot owns nothing in flight"), though
    // `beginShow` already cancels a stale one on its own, so that half is
    // belt-and-braces rather than a fix for an observed bug.
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _showConfirmTimer?.cancel();
    _showConfirmTimer = null;
    state.value = AdSlotState.idle;
    lastErrorAt = null;
    lastLoadedAt = null;
    consecutiveFailures = 0;
    _firePending(false);
  }

  /// Disposes [state]. Must be called exactly once, when the owning adapter
  /// is torn down — an undisposed `ValueNotifier` leaks its listeners for the
  /// adapter's lifetime.
  void dispose() {
    _watchdogTimer?.cancel();
    _showConfirmTimer?.cancel();
    state.dispose();
  }

  @override
  String toString() =>
      'AdSlot($type, ${value.name}, fails=$consecutiveFailures)';
}
