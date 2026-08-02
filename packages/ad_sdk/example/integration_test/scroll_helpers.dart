// Shared scroll helper for the on-device integration tests.
//
// Not named *_test.dart on purpose: CI globs `integration_test/*_test.dart`,
// so this file is imported but never run as a suite.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

extension SettledScrolling on WidgetTester {
  /// [scrollUntilVisible], then wait until the target actually stops moving.
  ///
  /// `scrollUntilVisible` drags in discrete steps and returns as soon as the
  /// finder matches — while the pointer-up it just sent is still driving a
  /// ballistic BouncingScrollPhysics animation. So the rect a finder reports
  /// immediately afterwards can already be stale by the time a tap's pointer
  /// is dispatched, and the tap lands on whatever moved under it.
  ///
  /// That is not theoretical. On the iOS Simulator in CI (~3.4x slower than
  /// the dev Mac, so the fling is still running where locally it has already
  /// settled) consent_country_demo_test failed with:
  ///
  ///     tap() ... derived an Offset (Offset(350.5, 568.0)) that would not
  ///     hit test on the specified widget
  ///     Expected: 'DE'  Actual: <null>
  ///
  /// — the tap missed, so the value under assert was never written. It passed
  /// on every local run. Waiting for the rect to be identical across three
  /// consecutive frames covers the fling, a keyboard inset animation, and
  /// whatever moves the target next, without having to enumerate them.
  Future<void> scrollUntilVisibleAndSettle(
    Finder target,
    double delta, {
    Finder? scrollable,
    int maxFrames = 60,
  }) async {
    await scrollUntilVisible(target, delta, scrollable: scrollable);

    Rect? previous;
    var stableFrames = 0;
    for (var i = 0; i < maxFrames; i++) {
      await pump(const Duration(milliseconds: 100));
      final current = getRect(target);
      stableFrames = current == previous ? stableFrames + 1 : 0;
      previous = current;
      // Three identical frames, not one: a single match can happen between
      // two steps of an easing curve that is still running.
      if (stableFrames >= 3) return;
    }
    fail('target never stopped moving after scrolling to it, so a tap would '
        'race the scroll animation: $target');
  }
}
