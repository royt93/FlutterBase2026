import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';

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
class InFeedAdListView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final total = InFeedIndexCalculator.totalCount(
      itemCount: itemCount,
      adInterval: adInterval,
    );

    return ListView.builder(
      key: key,
      scrollDirection: scrollDirection,
      reverse: reverse,
      controller: controller,
      primary: primary,
      physics: physics,
      shrinkWrap: shrinkWrap,
      padding: padding,
      itemCount: total,
      addAutomaticKeepAlives: addAutomaticKeepAlives,
      addRepaintBoundaries: addRepaintBoundaries,
      addSemanticIndexes: addSemanticIndexes,
      cacheExtent: cacheExtent,
      restorationId: restorationId,
      clipBehavior: clipBehavior,
      itemBuilder: (context, rawIndex) {
        if (InFeedIndexCalculator.isAdPosition(rawIndex, adInterval: adInterval)) {
          final adIndex = InFeedIndexCalculator.toAdIndex(rawIndex, adInterval: adInterval);
          if (adBuilder != null) {
            return adBuilder!(context, adIndex);
          }
          return const NativeAdWidget();
        }

        final originalIndex = InFeedIndexCalculator.toOriginalItemIndex(rawIndex, adInterval: adInterval);
        return itemBuilder(context, originalIndex);
      },
    );
  }
}
