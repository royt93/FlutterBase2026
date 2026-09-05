import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../core/ad_safety_config.dart';
import '../core/integration_self_check.dart';
import '../monetization/fill_rate_baseline_monitor.dart';
import '../state/ad_slot.dart';

/// Small floating panel showing realtime SDK state — only renders when
/// `kDebugMode == true`.
///
/// Wrap your home screen with this widget to keep an eye on ad lifecycle
/// during development:
///
/// ```dart
/// Stack(children: [
///   MyHomeScreen(),
///   const DebugAdOverlay(),
/// ])
/// ```
class DebugAdOverlay extends StatefulWidget {
  const DebugAdOverlay({
    super.key,
    this.alignment = Alignment.bottomLeft,
    this.padding = const EdgeInsets.all(8),
    this.enabled = true,
  });

  final Alignment alignment;
  final EdgeInsets padding;

  /// Per-instance opt-out — useful for QA screenshots, recording demos, or
  /// gating the panel behind a "developer mode" toggle in app settings.
  /// Release builds always hide the panel regardless of this value.
  final bool enabled;

  /// Process-wide toggle. Set to `false` to hide every [DebugAdOverlay]
  /// instance in the widget tree without rebuilding callers — handy from a
  /// debug shake-menu or an in-app dev console.
  static final ValueNotifier<bool> globallyVisible = ValueNotifier<bool>(true);

  @override
  State<DebugAdOverlay> createState() => _DebugAdOverlayState();
}

class _DebugAdOverlayState extends State<DebugAdOverlay> {
  final ValueNotifier<bool> _expanded = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _expanded.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode || !widget.enabled) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: DebugAdOverlay.globallyVisible,
      builder: (context, visible, _) {
        if (!visible) return const SizedBox.shrink();
        return SafeArea(
          child: Align(
            alignment: widget.alignment,
            child: Padding(
              padding: widget.padding,
              child: ValueListenableBuilder<bool>(
                valueListenable: _expanded,
                builder: (context, expanded, _) {
                  if (!expanded) {
                    return _Pill(
                      onTap: () => _expanded.value = true,
                      text: '🐛 Ad',
                    );
                  }
                  return _Panel(onClose: () => _expanded.value = false);
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.onTap, required this.text});
  final VoidCallback onTap;
  final String text;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(text,
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        ),
      );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.3,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('🐛 Ad SDK Debug',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  GestureDetector(
                    onTap: onClose,
                    child:
                        const Icon(Icons.close, color: Colors.white, size: 14),
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 12),
              _SlotRows(),
              const Divider(color: Colors.white24, height: 12),
              Text('Safety: ${AdSafetyConfig.getStatus()}',
                  maxLines: 3, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(
                'VIP=${AdManager().isVIPMember()}  '
                'init=${AdManager().isInitialised}  '
                'splash=${AdManager().isSplashActive}',
              ),
              const _FillRateRegressionRows(),
              const Divider(color: Colors.white24, height: 12),
              const _DoctorSection(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlotRows extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) {
        final ad = AdManager().adapter;
        if (ad == null) return const Text('(no adapter)');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _slotRow('AppOpen ', ad.appOpenSlot),
            _slotRow('Inter   ', ad.interstitialSlot),
            _slotRow('Rewarded', ad.rewardedSlot),
            // T65 (phase 2): banner is now keyed per BannerAdWidget instance
            // — no single slot to show here, same as mrec/native already.
          ],
        );
      },
    );
  }

  Widget _slotRow(String label, AdSlot slot) =>
      ValueListenableBuilder<AdSlotState>(
        valueListenable: slot.state,
        builder: (context, state, _) => Text(
            '$label ${state.name.padRight(9)} fails=${slot.consecutiveFailures}'),
      );
}

/// T97 — renders any active `FillRateBaselineMonitor` regression alerts.
/// Empty (renders nothing) when the monitor is disabled or nothing is
/// currently regressed — never adds a "no alerts" placeholder line.
class _FillRateRegressionRows extends StatefulWidget {
  const _FillRateRegressionRows();

  @override
  State<_FillRateRegressionRows> createState() =>
      _FillRateRegressionRowsState();
}

class _FillRateRegressionRowsState extends State<_FillRateRegressionRows> {
  StreamSubscription<FillRateRegressionAlert>? _sub;
  int? _subscribedRevision;

  @override
  void initState() {
    super.initState();
    _trySubscribe();
  }

  // Round-31 audit fix (MINOR) — `initState()` alone only catches the
  // monitor already existing at MOUNT time. This debug overlay (`kDebugMode`
  // only) can easily mount before `AdManager().initialize()`/
  // `enableFillRateBaselineMonitor()` runs, in which case `_sub` stayed
  // permanently null and new alerts never triggered a rebuild — only
  // visible again if something ELSE happened to rebuild this widget.
  // Cheap to retry every build: a debug tool, not a hot path, and a no-op
  // once subscribed.
  //
  // Round-38 audit fix (MINOR) — a bare `_sub != null` guard only ever
  // subscribes once. A `destroy()`+`initialize()` cycle in the same debug
  // session disposes the old monitor (closing its `StreamController`) and
  // hands out a new one, but this stayed latched onto the dead stream
  // forever — unlike `_SlotRows` above, which correctly rebuilds on
  // `initRevision`. Now keyed on the revision instead of a plain null-check,
  // and `build()` listens to `initRevision` too so a revision bump actually
  // triggers the resubscribe.
  void _trySubscribe() {
    final revision = AdManager().initRevision.value;
    if (_sub != null && _subscribedRevision == revision) return;
    _sub?.cancel();
    _subscribedRevision = revision;
    _sub = AdManager().fillRateBaselineMonitor?.alerts.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) {
        _trySubscribe();
        final alerts =
            AdManager().fillRateBaselineMonitor?.activeAlerts ?? const {};
        if (alerts.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final alert in alerts.values)
                Text(
                  '⚠️ ${alert.type.name} '
                  '${alert.fillRateRegressed ? 'fill ${(alert.sessionFillRate * 100).toStringAsFixed(0)}% '
                      'vs 7d ${(alert.baselineFillRate * 100).toStringAsFixed(0)}%' : ''}'
                  '${alert.fillRateRegressed && alert.revenueRegressed ? '  ' : ''}'
                  '${alert.revenueRegressed ? 'rev ${alert.sessionAvgRevenueMicros} '
                      'vs 7d ${alert.baselineAvgRevenueMicros}µ' : ''}',
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// T98 — manual "integration doctor" trigger + pass/fail results. NOT
/// auto-run on mount: `runIntegrationSelfCheck()` actually attempts real ad
/// loads (interstitial/rewarded/app-open), so it must only run when a
/// developer explicitly asks for it, never as a side effect of opening the
/// debug panel.
class _DoctorSection extends StatefulWidget {
  const _DoctorSection();

  @override
  State<_DoctorSection> createState() => _DoctorSectionState();
}

class _DoctorSectionState extends State<_DoctorSection> {
  SelfCheckResult? _result;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final result = await AdManager().runIntegrationSelfCheck();
    if (mounted) {
      setState(() {
        _result = result;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _running ? null : _run,
          child: Text(
            _running ? '🩺 Running doctor…' : '🩺 Run integration doctor',
            style: const TextStyle(
                color: Colors.lightBlueAccent,
                decoration: TextDecoration.underline),
          ),
        ),
        if (result != null)
          for (final item in result.items)
            Text(
              '${_statusIcon(item.status)} ${item.name}'
              '${item.detail != null ? ' — ${item.detail}' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _statusColor(item.status)),
            ),
      ],
    );
  }

  String _statusIcon(SelfCheckStatus s) => switch (s) {
        SelfCheckStatus.pass => '✅',
        SelfCheckStatus.fail => '❌',
        SelfCheckStatus.skipped => '⏭️',
      };

  Color _statusColor(SelfCheckStatus s) => switch (s) {
        SelfCheckStatus.pass => Colors.lightGreenAccent,
        SelfCheckStatus.fail => Colors.redAccent,
        SelfCheckStatus.skipped => Colors.white70,
      };
}
