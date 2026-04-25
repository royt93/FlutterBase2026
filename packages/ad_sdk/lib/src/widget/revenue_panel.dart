import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';

/// Tiny widget that subscribes to [AdManager.events] and shows running
/// revenue totals for the current session — useful in debug builds for
/// end-of-day eyeball checks.
///
/// ```dart
/// const RevenuePanel(showDecimals: true)
/// ```
class RevenuePanel extends StatefulWidget {
  const RevenuePanel({
    super.key,
    this.showDecimals = true,
    this.compact = false,
  });

  final bool showDecimals;
  final bool compact;

  @override
  State<RevenuePanel> createState() => _RevenuePanelState();
}

class _RevenuePanelState extends State<RevenuePanel> {
  final ValueNotifier<double> _totalUsd = ValueNotifier<double>(0);
  final ValueNotifier<int> _impressions = ValueNotifier<int>(0);
  StreamSubscription<AdEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = AdManager().events.listen(_onEvent);
  }

  void _onEvent(AdEvent event) {
    if (!mounted) return;
    if (event is AdRevenueEvent) {
      _totalUsd.value = _totalUsd.value + event.value;
      _impressions.value = _impressions.value + 1;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _totalUsd.dispose();
    _impressions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: _totalUsd,
      builder: (context, total, _) {
        return ValueListenableBuilder<int>(
          valueListenable: _impressions,
          builder: (context, count, _) {
            final formatted = widget.showDecimals
                ? total.toStringAsFixed(4)
                : total.toStringAsFixed(2);
            if (widget.compact) {
              return Text(
                'Rev: \$$formatted  /  $count imp',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              );
            }
            return Card(
              margin: const EdgeInsets.all(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Session Revenue',
                        style:
                            TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(
                      '\$$formatted',
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    Text('$count impressions',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.grey)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
