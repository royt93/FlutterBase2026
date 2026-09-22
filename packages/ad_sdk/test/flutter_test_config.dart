import 'dart:async';

import 'package:applovin_admob_sdk/src/core/ump_consent.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// Global test setup for every file under `test/` (Flutter's own convention
/// for this filename — no per-file import needed).
///
/// Round-39 audit fix (MAJOR, banner/MREC visibility) — `VisibilityDetector`
/// debounces its callback behind an internal `Timer` (default 500ms). Any
/// widget test that mounts a `BannerAdWidget`/`MrecAdWidget` and tears down
/// before that timer fires trips `flutter_test`'s own "no pending timers"
/// invariant. Setting this to zero is the package's own documented way to
/// make it fire synchronously, post-frame, in tests instead.
///
/// Round-71 audit fix — `AdManager.initialize()` now actually awaits its
/// auto-UMP flow instead of firing it in the background. Any test that
/// doesn't mock the UMP method channel used to pay nothing for that; now it
/// pays `requestConsentInfoUpdate`'s real 20s network timeout, once per
/// `initialize()` call, since nothing ever completes its callback. Shortened
/// suite-wide here rather than mocking the channel in every affected file —
/// a mocked file overrides this by actually answering the channel, so this
/// value only matters for the (many) files that don't care about UMP at all.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  debugRequestConsentInfoUpdateTimeoutOverride =
      const Duration(milliseconds: 200);
  await testMain();
}
