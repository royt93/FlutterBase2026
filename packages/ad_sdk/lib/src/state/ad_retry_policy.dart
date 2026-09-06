import 'dart:math' as math;

import 'backoff.dart';

/// T108 — optional per-slot retry policy layered on top of the shared
/// [Backoff] curve. A slot with [AdSlot.retryPolicy] left `null` (the
/// default) behaves exactly as before: plain [Backoff], every error
/// retryable, no jitter, no early reset on reconnect.
///
/// no-fill, network, invalid-request and timeout failures do not mean the
/// same thing — a misconfigured ad unit will never self-resolve by retrying,
/// while a network blip should often retry the moment connectivity returns
/// rather than waiting out the full backoff window. This lets a host encode
/// that distinction per slot without changing the SDK's default behavior.
class AdRetryPolicy {
  const AdRetryPolicy({
    this.backoff = const Backoff(),
    this.jitterFraction = 0.0,
    this.isRetryable,
    this.resetOnConnectivityRestored = false,
  }) : assert(jitterFraction >= 0 && jitterFraction <= 1,
            'jitterFraction is a fraction of the computed delay, 0..1');

  /// Same exponential curve as the process-wide default — see [Backoff].
  final Backoff backoff;

  /// Randomizes the computed delay by up to ±[jitterFraction] (e.g. `0.2` =
  /// ±20%) so slots that failed at the same instant (a shared network
  /// outage) don't all retry in lockstep. `0.0` (default) = no jitter,
  /// identical to plain [Backoff]. The draw is seeded from the failure's own
  /// [DateTime]/failure-count, not a fresh [math.Random] per check, so
  /// repeated cooldown checks against the same failure agree with each other
  /// instead of flip-flopping.
  final double jitterFraction;

  /// Given the adapter's raw numeric error code (see [AdLoadEvent.errorCode]
  /// — AdMob's `ErrorCode`/AppLovin's `MaxAdError.code`, provider-specific —
  /// `null` when the caller didn't have one to pass), decide whether this
  /// failure is worth retrying at all. `null` (default) retries everything,
  /// matching current behavior. Return `false` for errors that will never
  /// self-resolve (e.g. a misconfigured/invalid ad unit) — the slot then
  /// stays in cooldown until [AdSlot.reset] runs (a fresh SDK
  /// destroy()+initialize()), instead of hammering the network forever.
  final bool Function(int? errorCode)? isRetryable;

  /// When true, [AdSlot.clearCooldownOnReconnect] clears this slot's backoff
  /// window early instead of waiting out the computed delay. Off by default
  /// — a real no-fill/invalid-request is not a connectivity problem, so
  /// retrying it early would just burn another wasted request the moment the
  /// network blips back.
  final bool resetOnConnectivityRestored;

  /// Whether a load can start right now, given the slot's failure history.
  /// Mirrors [Backoff.isInCooldown] but adds the retryable-error gate and
  /// jitter. [random] is exposed purely for deterministic unit testing —
  /// production callers omit it.
  bool canRetryNow({
    required DateTime? lastErrorAt,
    required int consecutiveFailures,
    required int? lastErrorCode,
    math.Random? random,
  }) {
    if (lastErrorAt == null) return true;
    if (isRetryable != null && !isRetryable!(lastErrorCode)) return false;
    final base = backoff.compute(consecutiveFailures);
    final elapsed = DateTime.now().difference(lastErrorAt).inMilliseconds;
    if (jitterFraction <= 0) return elapsed >= base;
    final rand = random ??
        math.Random(lastErrorAt.microsecondsSinceEpoch ^ consecutiveFailures);
    final jitterMs = base * jitterFraction * (rand.nextDouble() * 2 - 1);
    // Round-39 audit fix (MINOR) — a `jitterFraction` near 1.0 combined with
    // an unlucky draw could collapse `delay` all the way to ~0, retrying
    // immediately regardless of `consecutiveFailures` and defeating backoff
    // entirely. Floor it at 10% of the un-jittered `base` so jitter can only
    // ever shorten the wait, never erase it.
    final floor = (base * 0.1).round();
    final delay = (base + jitterMs).round().clamp(floor, backoff.maxMs);
    return elapsed >= delay;
  }
}
