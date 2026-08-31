/// T115 — a single cancellation/epoch primitive meant to eventually replace
/// the generation-int, bool-disposed, Timer-identity, and Completer idioms
/// used ad hoc across this SDK (`ad_manager.dart`, both adapters, UMP, VIP
/// manager, the splash controller, the loading dialog) to answer the same
/// question each of them re-derives on its own: "is the async work I'm
/// about to act on still the one that's current, or did something newer
/// (a `destroy()`, a fresh `initialize()`, a superseding call) start since?"
///
/// Deliberately internal (not exported) and deliberately NOT yet wired into
/// any of those call sites — migrating each one is real, individually
/// risky work on files this SDK has audited 26+ rounds, and belongs to a
/// dedicated follow-up ticket per subsystem, not a mechanical find/replace.
/// This class only needs to exist and be correct on its own first.
class AsyncEpoch {
  int _generation = 0;
  bool _disposed = false;

  /// Capture before starting async work; pass back to [isCurrent] after an
  /// `await` to check whether [invalidate] or [dispose] ran meanwhile.
  int get token => _generation;

  /// Invalidates every [token] issued before now — the async work they
  /// guard should treat itself as stale and stop acting on shared state.
  void invalidate() {
    if (_disposed) return;
    _generation++;
  }

  /// Whether [token] (captured via [this.token] before an await) is still
  /// the current generation. Always `false` once [dispose] has run.
  bool isCurrent(int token) => !_disposed && token == _generation;

  /// Permanently disposes this epoch — [isCurrent] returns `false` for
  /// every token, past or future, from this point on. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
  }

  bool get isDisposed => _disposed;

  @override
  String toString() =>
      'AsyncEpoch(generation: $_generation, disposed: $_disposed)';
}
