import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../utils/safe_logger.dart';

/// Tiny widget that subscribes to [AdManager.events] and shows running
/// revenue totals for the current session — useful in debug builds for
/// end-of-day eyeball checks.
///
/// F9 — gated on [kDebugMode]: renders nothing and never subscribes in a
/// release build, so a host that leaves this mounted by accident doesn't
/// leak session revenue figures to end users.
///
/// ```dart
/// const RevenuePanel(showDecimals: true)
/// ```
class RevenuePanel extends StatefulWidget {
  const RevenuePanel({
    super.key,
    this.showDecimals = true,
    this.compact = false,
    this.debugModeOverride,
  });

  final bool showDecimals;
  final bool compact;

  /// Test-only seam — [kDebugMode] is a compile-time constant so it can't be
  /// toggled from a running `flutter test`, mirroring the
  /// `platformIsIosOverride` pattern in `att_consent.dart`.
  @visibleForTesting
  final bool? debugModeOverride;

  @override
  State<RevenuePanel> createState() => _RevenuePanelState();
}

class _RevenuePanelState extends State<RevenuePanel> {
  final ValueNotifier<double> _totalUsd = ValueNotifier<double>(0);
  final ValueNotifier<int> _impressions = ValueNotifier<int>(0);
  StreamSubscription<AdEvent>? _sub;

  bool get _isDebug => widget.debugModeOverride ?? kDebugMode;

  @override
  void initState() {
    super.initState();
    if (_isDebug) {
      _sub = AdManager().events.listen(_onEvent);
    }
  }

  static const String _tag = 'RevenuePanel';
  bool _warnedNonUsd = false;

  void _onEvent(AdEvent event) {
    if (!mounted) return;
    if (event is AdRevenueEvent) {
      // T135 — _totalUsd is a USD-only running sum (the UI prefixes it
      // with a bare '$'); event.value is just valueMicros / 1_000_000, a
      // pure arithmetic conversion with no currency conversion behind it.
      // Adding a non-USD event's raw value here would silently mix
      // currencies into one number with no unit conversion — wrong, not
      // just imprecise. Skip it instead (impressions still count — that
      // part is currency-agnostic); log once so a host actually running
      // multi-currency mediation notices instead of wondering why the
      // total looks off.
      if (event.currencyCode == 'USD') {
        _totalUsd.value = _totalUsd.value + event.value;
      } else if (!_warnedNonUsd) {
        _warnedNonUsd = true;
        SafeLogger.w(_tag,
            'AdRevenueEvent with currencyCode=${event.currencyCode} (not USD) — skipping it in the USD total to avoid mixing currencies. (further non-USD events will be skipped silently)');
      }
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
    if (!_isDebug) return const SizedBox.shrink();
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
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(
                      '\$$formatted',
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    Text('$count impressions',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
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
