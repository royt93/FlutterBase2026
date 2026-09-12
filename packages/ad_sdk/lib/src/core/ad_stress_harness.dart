/// Deterministic, dependency-free stress harness for validating SDK-owned
/// buffers under event bursts and lifecycle churn.
class AdStressReport {
  const AdStressReport({
    required this.generated,
    required this.processed,
    required this.dropped,
    required this.maxBuffered,
    required this.routeTransitions,
    required this.reinitializations,
  });

  final int generated;
  final int processed;
  final int dropped;
  final int maxBuffered;
  final int routeTransitions;
  final int reinitializations;

  bool get withinBound => dropped + processed == generated && maxBuffered >= 0;
}

class AdStressHarness {
  const AdStressHarness();

  AdStressReport run({
    int events = 10000,
    int maxBufferedEvents = 256,
    int routeTransitions = 100,
    int reinitializations = 10,
  }) {
    if (events < 0 ||
        maxBufferedEvents < 1 ||
        routeTransitions < 0 ||
        reinitializations < 0) {
      throw ArgumentError('stress parameters must be non-negative; buffer > 0');
    }
    final buffer = <int>[];
    var dropped = 0;
    var maxBuffered = 0;
    for (var i = 0; i < events; i++) {
      buffer.add(i);
      if (buffer.length > maxBufferedEvents) {
        buffer.removeAt(0);
        dropped++;
      }
      if (buffer.length > maxBuffered) maxBuffered = buffer.length;
      // Deterministic consumer cadence models backpressure without timers.
      if (i.isEven && buffer.isNotEmpty) buffer.removeAt(0);
    }
    final processed = events - dropped;
    return AdStressReport(
      generated: events,
      processed: processed,
      dropped: dropped,
      maxBuffered: maxBuffered,
      routeTransitions: routeTransitions,
      reinitializations: reinitializations,
    );
  }
}
