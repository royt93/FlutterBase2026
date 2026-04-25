import 'dart:math' as math;

/// Exponential-backoff cooldown calculator (Phase 6 — Q19B).
///
/// Replaces the legacy fixed 15-min cooldown. Computes wait based on
/// consecutive failures:
///
///     wait = base * 2^failures, capped at [maxMs]
///
/// Defaults: base 15 s, cap 30 min. So a slot that fails 7+ times in a row
/// would wait 30 min between retries; a transient single-fail waits 15 s.
class Backoff {
  const Backoff({
    this.baseMs = 15 * 1000,
    this.maxMs = 30 * 60 * 1000,
  });

  final int baseMs;
  final int maxMs;

  int compute(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return 0;
    final shifted = baseMs * math.pow(2, consecutiveFailures - 1).toInt();
    return shifted.clamp(baseMs, maxMs);
  }

  /// Whether [lastErrorAt] is still inside the backoff window for the
  /// current consecutive-failure count.
  bool isInCooldown({
    required DateTime? lastErrorAt,
    required int consecutiveFailures,
  }) {
    if (lastErrorAt == null) return false;
    final elapsed = DateTime.now().difference(lastErrorAt).inMilliseconds;
    return elapsed < compute(consecutiveFailures);
  }
}
