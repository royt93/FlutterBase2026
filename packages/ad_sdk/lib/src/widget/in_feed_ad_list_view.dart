import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';

import '../utils/safe_logger.dart';
import 'native_ad_widget.dart';

/// Helper to calculate indices when inserting ads into a list at fixed intervals.
class InFeedIndexCalculator {
  const InFeedIndexCalculator._();

  /// Whether a raw list position is an ad position.
  ///
  /// For [adInterval] = N, positions (N), (2N + 1), (3N + 2)... are ads.
  /// That is, an ad appears after every N content items.
  static bool isAdPosition(int rawIndex, {required int adInterval}) {
    assert(adInterval > 0, 'adInterval must be greater than 0');
    return (rawIndex + 1) % (adInterval + 1) == 0;
  }

  /// Maps a raw list index to the corresponding content item index in the original list.
  /// Returns null if [rawIndex] is an ad position.
  static int toOriginalItemIndex(int rawIndex, {required int adInterval}) {
    assert(adInterval > 0, 'adInterval must be greater than 0');
    final adCountBefore = rawIndex ~/ (adInterval + 1);
    return rawIndex - adCountBefore;
  }

  /// Calculates which ad slot number (0-based) corresponds to [rawIndex].
  static int toAdIndex(int rawIndex, {required int adInterval}) {
    assert(adInterval > 0, 'adInterval must be greater than 0');
    return (rawIndex + 1) ~/ (adInterval + 1) - 1;
  }

  /// Total count of elements in the raw list, including both content items and inserted ads.
  static int totalCount({required int itemCount, required int adInterval}) {
    assert(adInterval > 0, 'adInterval must be greater than 0');
    if (itemCount <= 0) return 0;
    final adCount = itemCount ~/ adInterval;
    return itemCount + adCount;
  }
}

/// A ListView wrapper that automatically interleaves [NativeAdWidget] (or a custom ad widget)
/// into a feed at a specified interval.
class InFeedAdListView extends StatefulWidget {
  const InFeedAdListView.builder({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.adInterval = 10,
    this.adBuilder,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.controller,
    this.primary,
    this.physics,
    this.shrinkWrap = false,
    this.padding,
    this.addAutomaticKeepAlives = false,
    this.addRepaintBoundaries = true,
    this.addSemanticIndexes = true,
    this.cacheExtent,
    this.dragStartBehavior = DragStartBehavior.start,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.restorationId,
    this.clipBehavior = Clip.hardEdge,
  }) : assert(adInterval > 0, 'adInterval must be greater than 0');

  /// The total number of content items in the original feed.
  final int itemCount;

  /// Builder for content items. Receives the original unshifted item index (0 <= index < itemCount).
  final NullableIndexedWidgetBuilder itemBuilder;

  /// The number of content items between each ad. Defaults to 10.
  final int adInterval;

  /// Optional custom builder for the ad widget at [adIndex] (0-based ad counter).
  /// If null, defaults to building a `NativeAdWidget()`.
  final Widget Function(BuildContext context, int adIndex)? adBuilder;

  final Axis scrollDirection;
  final bool reverse;
  final ScrollController? controller;
  final bool? primary;
  final ScrollPhysics? physics;
  final bool shrinkWrap;
  final EdgeInsetsGeometry? padding;
  final bool addAutomaticKeepAlives;
  final bool addRepaintBoundaries;
  final bool addSemanticIndexes;
  final double? cacheExtent;
  final DragStartBehavior dragStartBehavior;
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;
  final String? restorationId;
  final Clip clipBehavior;

  @override
  State<InFeedAdListView> createState() => _InFeedAdListViewState();
}

/// T225 — scroll-settle gate for in-feed native ads.
///
/// While the list is scrolling, newly mounted `NativeAdWidget` slots are
/// built with `active: false` so they hold a fixed-height placeholder
/// (no network load, no layout shift). On settle they flip back to
/// `active: true` and load normally through `NativeAdWidget`'s own
/// dedup/throttle gates (`canLoadNative`, `AdSlot.beginLoad`).
///
/// Custom `adBuilder`s are passed through untouched — the SDK cannot know
/// whether they load ads, and gating arbitrary caller widgets behind a
/// settles-flag would silently swallow their content.
class _InFeedAdListViewState extends State<InFeedAdListView> {
  static const String _tag = 'InFeedAdListView';

  /// True between ScrollStartNotification and the matching
  /// ScrollEndNotification. Only these two are authoritative: update and
  /// overscroll notifications can arrive after the end (edge bounce,
  /// ballistic tail) with no further end following, so letting them set
  /// this flag leaves it stuck true and defers loads forever.
  final ValueNotifier<bool> _scrolling = ValueNotifier<bool>(false);

  bool _onScrollNotification(ScrollNotification notification) {
    // Ignore carousels/PageViews nested inside feed rows. Their notifications
    // bubble through this listener with depth > 0, but the feed itself is not
    // moving and must not suppress its native loads.
    if (notification.depth != 0) return false;
    if (notification is ScrollEndNotification) {
      if (_scrolling.value) {
        SafeLogger.d(_tag, 'scroll settled — releasing deferred native loads');
        _scrolling.value = false;
      }
    } else if (notification is ScrollStartNotification) {
      if (!_scrolling.value) {
        SafeLogger.d(_tag, 'in-feed load deferred — scroll in flight');
        _scrolling.value = true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _scrolling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = InFeedIndexCalculator.totalCount(
      itemCount: widget.itemCount,
      adInterval: widget.adInterval,
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView.builder(
        scrollDirection: widget.scrollDirection,
        reverse: widget.reverse,
        controller: widget.controller,
        primary: widget.primary,
        physics: widget.physics,
        shrinkWrap: widget.shrinkWrap,
        padding: widget.padding,
        itemCount: total,
        addAutomaticKeepAlives: widget.addAutomaticKeepAlives,
        addRepaintBoundaries: widget.addRepaintBoundaries,
        addSemanticIndexes: widget.addSemanticIndexes,
        cacheExtent: widget.cacheExtent,
        restorationId: widget.restorationId,
        clipBehavior: widget.clipBehavior,
        itemBuilder: (context, rawIndex) {
          if (InFeedIndexCalculator.isAdPosition(
            rawIndex,
            adInterval: widget.adInterval,
          )) {
            final adIndex = InFeedIndexCalculator.toAdIndex(
              rawIndex,
              adInterval: widget.adInterval,
            );
            if (widget.adBuilder != null) {
              return widget.adBuilder!(context, adIndex);
            }
            // T225 — deferred slots keep their own height across the active
            // flip via `_NativePlaceholder`: `NativeAdWidget` itself renders
            // a zero-height `SizedBox.shrink()` while inactive, so this
            // fixed-height shell is what holds the slot open. Fixed
            // provider heights would be wrong here: the AppLovin branch
            // renders compliance chrome (badge row + vertical padding) on
            // top of the 320 medium template, so `NativeAdWidget` has no
            // single intrinsic height.
            return ValueListenableBuilder<bool>(
              valueListenable: _scrolling,
              builder: (context, scrolling, _) =>
                  _NativePlaceholder(active: !scrolling),
            );
          }

          final originalIndex = InFeedIndexCalculator.toOriginalItemIndex(
            rawIndex,
            adInterval: widget.adInterval,
          );
          return widget.itemBuilder(context, originalIndex);
        },
      ),
    );
  }
}

/// T225 — fixed placeholder shell for deferred slots.
///
/// `NativeAdWidget` itself renders a zero-height `SizedBox.shrink()` while
/// inactive, so this outer box holds the slot open. The real widget is not
/// constrained: `ConstrainedBox(minHeight: 320)` lets AppLovin's compliance
/// chrome grow beyond the medium-template minimum while AdMob remains 320,
/// avoiding the clipping a tight `SizedBox(height: 320)` caused.
class _NativePlaceholder extends StatelessWidget {
  const _NativePlaceholder({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 320),
      child: NativeAdWidget(active: active),
    );
  }
}
