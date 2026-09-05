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
    // Round-37 audit MAJOR — `math.pow(2, n)` on two `int` arguments silently
    // wraps 64-bit two's-complement on overflow (Dart does not throw), and
    // `baseMs * 2^(n-1)` overflows int64 once n gets into the 50s with the
    // default 15s base. The wrapped (often negative) result then made
    // `.clamp(baseMs, maxMs)` return the *lower* bound instead of holding the
    // maxMs cap — collapsing the backoff to its minimum right when a slot has
    // been failing for hours. Doubling in a loop and stopping the moment we
    // reach maxMs never produces a number anywhere near overflow, and the
    // iteration cap is a second, redundant guard for the same reason.
    var shifted = baseMs;
    var iterations = consecutiveFailures - 1;
    if (iterations > 62) iterations = 62;
    for (var i = 0; i < iterations && shifted < maxMs; i++) {
      shifted *= 2;
    }
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
