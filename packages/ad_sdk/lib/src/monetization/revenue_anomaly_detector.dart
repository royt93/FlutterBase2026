enum RevenueAnomalyKind {
  zeroEcpm,
  spike,
  currencyMismatch,
  duplicateImpression,
  requestIdCollision,
}

class RevenueAnomaly {
  const RevenueAnomaly(this.kind, this.message, {this.requestId});
  final RevenueAnomalyKind kind;
  final String message;
  final String? requestId;
}

/// Observe-only revenue anomaly detector. It never blocks ads or changes
/// monetization decisions; hosts decide how to surface [RevenueAnomaly]s.
class RevenueAnomalyDetector {
  const RevenueAnomalyDetector({this.minimumSamples = 5});
  final int minimumSamples;

  List<RevenueAnomaly> analyze(Iterable<Map<String, dynamic>> entries) {
    if (minimumSamples < 1) throw ArgumentError.value(minimumSamples);
    final list = entries
        .where((e) => e['eventType'] == 'AdRevenueEvent')
        .toList(growable: false);
    if (list.length < minimumSamples) return const [];
    final anomalies = <RevenueAnomaly>[];
    final values = list.map((e) => e['valueMicros'] as int? ?? 0).toList()
      ..sort();
    final median = values[values.length ~/ 2];
    final deviations = values.map((v) => (v - median).abs()).toList()..sort();
    final mad = deviations[deviations.length ~/ 2];
    final spikeFloor = median * 3;
    final spikeLimit = median + (mad * 3 > spikeFloor ? mad * 3 : spikeFloor);
    for (final event in list) {
      final value = event['valueMicros'] as int? ?? 0;
      if (value == 0) {
        anomalies.add(const RevenueAnomaly(
            RevenueAnomalyKind.zeroEcpm, 'zero eCPM revenue event'));
      } else if (value > spikeLimit && median > 0) {
        anomalies.add(RevenueAnomaly(RevenueAnomalyKind.spike,
            'eCPM spike $value > robust limit $spikeLimit'));
      }
    }
    final currencies = list
        .map((e) => (e['currencyCode'] as String? ?? '').toUpperCase())
        .where((c) => c.isNotEmpty)
        .toSet();
    if (currencies.length > 1) {
      anomalies.add(RevenueAnomaly(RevenueAnomalyKind.currencyMismatch,
          'mixed currencies: ${currencies.join(',')}'));
    }
    final seen = <String, Map<String, dynamic>>{};
    for (final event in list) {
      final id = event['requestId'] as String?;
      if (id == null || id.isEmpty) continue;
      final previous = seen[id];
      if (previous != null) {
        final collision = previous['providerTag'] != event['providerTag'] ||
            previous['slotType'] != event['slotType'];
        anomalies.add(RevenueAnomaly(
          collision
              ? RevenueAnomalyKind.requestIdCollision
              : RevenueAnomalyKind.duplicateImpression,
          collision
              ? 'requestId used by multiple ad contexts'
              : 'duplicate impression requestId=$id',
          requestId: id,
        ));
      } else {
        seen[id] = event;
      }
    }
    return anomalies;
  }
}
