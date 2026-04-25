import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../core/ad_safety_config.dart';
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
  static final ValueNotifier<bool> globallyVisible =
      ValueNotifier<bool>(true);

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
                    child: const Icon(Icons.close, color: Colors.white, size: 14),
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
            _slotRow('Banner  ', ad.bannerSlot),
          ],
        );
      },
    );
  }

  Widget _slotRow(String label, AdSlot slot) =>
      ValueListenableBuilder<AdSlotState>(
        valueListenable: slot.state,
        builder: (context, state, _) =>
            Text('$label ${state.name.padRight(9)} fails=${slot.consecutiveFailures}'),
      );
}
