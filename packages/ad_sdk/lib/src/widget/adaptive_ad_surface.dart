import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/ad_manager.dart';
import '../state/ad_placement.dart';
import '../state/ad_sdk_state_snapshot.dart';
import 'banner_ad_widget.dart';
import 'mrec_ad_widget.dart';

/// T124 — a single widget that picks between [BannerAdWidget] and
/// [MrecAdWidget] based on the available width, instead of a host hardcoding
/// one format per screen.
///
/// Below [mrecBreakpoint] logical pixels wide (the default, 600, matches a
/// typical phone-vs-tablet/foldable cutover) renders a banner; at or above
/// it renders an MREC. Rotation is covered implicitly: turning a phone to
/// landscape widens the available box the same way a tablet would.
///
/// Switching format debounces by [resizeDebounce] — a rotation or a
/// transient layout pass during an animation shouldn't tear down and
/// recreate the ad mid-gesture — except the very first layout, which
/// commits immediately (nothing to debounce yet). While a fullscreen ad (or
/// the loading buffer) owns the screen (`AdSdkStateSnapshot.fullscreenBusy`,
/// T109), the format is frozen — never swapped underneath a surface the
/// user can't currently see is being resized.
///
/// A distinct [ValueKey] per format means Flutter tears down the old
/// widget's `State` (and with it, the old ad instance) before mounting the
/// new one — no leaked instance ownership across a switch.
///
/// Native is deliberately not one of the choices in this v1: unlike
/// banner/MREC, a native template's content is host-authored (headline,
/// CTA copy, images), so auto-swapping into it based on width alone would
/// need a content contract this widget doesn't have — left for a
/// follow-up rather than guessed at here.
class AdaptiveAdSurface extends StatefulWidget {
  const AdaptiveAdSurface({
    super.key,
    this.placement = AdPlacement.unspecified,
    this.mrecBreakpoint = 600,
    this.resizeDebounce = const Duration(milliseconds: 200),
  });

  final AdPlacement placement;

  /// Width (logical pixels) at or above which an MREC is chosen instead of
  /// a banner.
  final double mrecBreakpoint;

  /// How long a width change must persist before the format actually
  /// switches. The very first layout is exempt — it commits immediately.
  final Duration resizeDebounce;

  @override
  State<AdaptiveAdSurface> createState() => _AdaptiveAdSurfaceState();
}

enum _Surface { banner, mrec }

class _AdaptiveAdSurfaceState extends State<AdaptiveAdSurface> {
  _Surface? _current;
  Timer? _debounce;

  _Surface _surfaceFor(double width) =>
      width >= widget.mrecBreakpoint ? _Surface.mrec : _Surface.banner;

  void _onLayout(double width, bool fullscreenBusy) {
    if (fullscreenBusy) return;
    final target = _surfaceFor(width);

    if (_current == null) {
      // First layout — nothing to debounce against yet, commit right away.
      _current = target;
      return;
    }
    if (target == _current) {
      _debounce?.cancel();
      _debounce = null;
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(widget.resizeDebounce, () {
      if (!mounted) return;
      setState(() => _current = target);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AdSdkStateSnapshot>(
      valueListenable: AdManager().stateSnapshot,
      builder: (context, snapshot, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            _onLayout(constraints.maxWidth, snapshot.fullscreenBusy);
            return switch (_current ?? _Surface.banner) {
              _Surface.banner => BannerAdWidget(
                  key: const ValueKey('adaptive-ad-surface-banner'),
                  placement: widget.placement,
                ),
              _Surface.mrec => MrecAdWidget(
                  key: const ValueKey('adaptive-ad-surface-mrec'),
                  placement: widget.placement,
                ),
            };
          },
        );
      },
    );
  }
}
