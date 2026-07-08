/// T26 Phase 1 — instrumentation only. Records two cheap on-device proxy
/// signals for ad fatigue, WITHOUT adjusting any cap:
///
/// - `ad_to_background`: app backgrounded shortly after a fullscreen ad
///   (recorded from [AdSafetyConfig.recordAppWentBackground]).
/// - `background_to_resume`: gap between that backgrounding and the next
///   resume (recorded from [AdSafetyConfig.canShowAppOpenOnResume]).
///
/// Both hooks reuse call sites [AdSafetyConfig] already has for its own caps
/// — no new lifecycle wiring. Phase 2 (using these signals to lower a soft
/// cap below the hard `AdSafetyParams` ceiling) is intentionally unscoped
/// until real data justifies it — see
/// doc/task/done/T26-adaptive-frequency-capping.md.
class AdaptiveFrequencySignal {
  const AdaptiveFrequencySignal({
    required this.kind,
    required this.timestampMs,
    required this.gapMs,
  });

  /// `'ad_to_background'` or `'background_to_resume'`.
  final String kind;
  final int timestampMs;
  final int gapMs;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'timestampMs': timestampMs,
        'gapMs': gapMs,
      };
}

/// Rolling, in-memory (not persisted — Phase 1 diagnostic only) buffer of
/// [AdaptiveFrequencySignal]s, capped so a long session can't grow it
/// unbounded.
class AdaptiveFrequencySignals {
  AdaptiveFrequencySignals._();

  static const int _maxEntries = 500;
  static final List<AdaptiveFrequencySignal> _entries = [];

  static void Function(AdaptiveFrequencySignal)? _sink;

  /// Wire a sink (e.g. into `AdEventLog`) — call once from
  /// `AdManager.initialize()`. Mirrors [AdSafetyConfig]'s `_anomalySink`
  /// injection pattern.
  static void setSink(void Function(AdaptiveFrequencySignal) sink) {
    _sink = sink;
  }

  static void record(String kind, int timestampMs, int gapMs) {
    final signal = AdaptiveFrequencySignal(
        kind: kind, timestampMs: timestampMs, gapMs: gapMs);
    _entries.add(signal);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _sink?.call(signal);
  }

  /// Read-only view, oldest first.
  static List<AdaptiveFrequencySignal> get entries =>
      List.unmodifiable(_entries);

  static void reset() {
    _entries.clear();
    _sink = null;
  }
}
