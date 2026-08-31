// T117 — AdEvent stream live viewer. Split out of main.dart. EventRow
// itself lives in shared/event_buffer.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

import '../shared/event_buffer.dart';
import '../shared/layout_helpers.dart';

class EventsDemoPage extends StatelessWidget {
  const EventsDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AdEvent stream'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Clear',
            onPressed: () => EventBuffer.instance.clear(),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Tap any other demo (banner, inter, rewarded, app-open) and '
              'come back — every load/show/click/reward/revenue event from '
              'the SDK is logged here in real time.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: EventBuffer.instance.revision,
              builder: (_, __, ___) {
                final rows = EventBuffer.instance.snapshot();
                if (rows.isEmpty) {
                  return const Center(
                    child: Text('(no events yet — trigger an ad somewhere)',
                        style: TextStyle(color: Colors.grey)),
                  );
                }
                return ListView.separated(
                  padding: bottomSafe(context, EdgeInsets.zero),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final row = rows[i];
                    return _EventTile(row: row);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.row});
  final EventRow row;

  @override
  Widget build(BuildContext context) {
    final e = row.event;
    final time = row.timestamp.toIso8601String().substring(11, 19);
    final (label, color, detail) = _describe(e);
    return ListTile(
      dense: true,
      leading: Container(
        width: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                fontSize: 10)),
      ),
      title: Text(
        e is AdAnomalyEvent
            ? e.reason
            : '${e.providerTag} ${e.type.name} @${e.placement.id}',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      subtitle: Text(
        '$time  $detail',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }

  (String, Color, String) _describe(AdEvent e) {
    if (e is AdLoadEvent) {
      return (
        e.success ? 'LOAD✓' : 'LOAD✗',
        e.success ? Colors.blue : Colors.red,
        e.success ? 'loaded' : 'errCode=${e.errorCode ?? '?'}',
      );
    }
    if (e is AdShowEvent) {
      return (
        e.success ? 'SHOW✓' : 'SHOW✗',
        e.success ? Colors.green : Colors.orange,
        e.success ? 'shown' : 'skipped',
      );
    }
    if (e is AdClickEvent) return ('CLICK', Colors.purple, 'user clicked');
    if (e is AdRewardEvent) {
      return (
        'REWARD',
        Colors.amber.shade700,
        '${e.label ?? '?'} × ${e.amount ?? 0}'
      );
    }
    if (e is AdRevenueEvent) {
      final waterfall = e.mediationWaterfall;
      return (
        'REV \$',
        Colors.teal,
        '\$${e.value.toStringAsFixed(6)} ${e.currencyCode}'
            '${e.networkName != null ? ' via ${e.networkName}' : ''}'
            '${waterfall != null && waterfall.isNotEmpty ? '\nwaterfall: ${waterfall.join(' > ')}' : ''}',
      );
    }
    if (e is AdAnomalyEvent) {
      return (
        'ANOMALY',
        Colors.redAccent,
        'violation #${e.violationCount} · paused ${e.pauseDurationMs ~/ 60000}min',
      );
    }
    if (e is ArbitratorNudgeEvent) {
      return (
        'NUDGE',
        Colors.indigo,
        'vetoed low-eCPM ad · trailing eCPM=\$${e.estimatedEcpmMicros / 1e6}',
      );
    }
    return ('?', Colors.grey, '');
  }
}
