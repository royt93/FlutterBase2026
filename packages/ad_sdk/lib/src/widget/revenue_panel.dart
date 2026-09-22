import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';

/// T186 — running totals for one [AdSlotType], shown in the per-type
/// breakdown below the session summary.
@immutable
class RevenueTypeStats {
  const RevenueTypeStats({required this.totalUsd, required this.impressions});

  final double totalUsd;
  final int impressions;
}

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

  /// T186 — per-[AdSlotType] breakdown, USD-only (same skip rule as
  /// [_totalUsd] — see [_onEvent]'s comment). A fresh `Map` on every
  /// update rather than a mutated one in place, so `ValueListenableBuilder`
  /// actually sees a new identity to rebuild against.
  final ValueNotifier<Map<AdSlotType, RevenueTypeStats>> _byType =
      ValueNotifier<Map<AdSlotType, RevenueTypeStats>>(const {});

  StreamSubscription<AdEvent>? _sub;

  // Round-72 audit follow-up (4th independent review) — `kReleaseMode` is a
  // compile-time constant, so this can't be bypassed by leaving
  // `debugModeOverride: true` in release: a real live-revenue number would
  // otherwise be shown to the end user instead of staying hidden.
  bool get _isDebug =>
      kReleaseMode ? false : (widget.debugModeOverride ?? kDebugMode);

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
        // T186 — same USD-only rule as the session total above: mixing an
        // unconverted non-USD value into a per-type USD figure would be
        // just as wrong as mixing it into the session total.
        final prev = _byType.value[event.type];
        final updated = RevenueTypeStats(
          totalUsd: (prev?.totalUsd ?? 0) + event.value,
          impressions: (prev?.impressions ?? 0) + 1,
        );
        _byType.value = {..._byType.value, event.type: updated};
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
    _byType.dispose();
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
                    // T186 — per-type breakdown below the session summary.
                    ValueListenableBuilder<Map<AdSlotType, RevenueTypeStats>>(
                      valueListenable: _byType,
                      builder: (context, byType, _) {
                        if (byType.isEmpty) return const SizedBox.shrink();
                        final sortedTypes = byType.keys.toList()
                          ..sort((a, b) => a.name.compareTo(b.name));
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            const Divider(height: 1),
                            const SizedBox(height: 8),
                            for (final type in sortedTypes)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 1),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(type.name,
                                        style: const TextStyle(fontSize: 11)),
                                    const SizedBox(width: 8),
                                    Text(
                                      '\$${(widget.showDecimals ? byType[type]!.totalUsd.toStringAsFixed(4) : byType[type]!.totalUsd.toStringAsFixed(2))}'
                                      '  /  ${byType[type]!.impressions} imp',
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
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
