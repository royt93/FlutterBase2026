import 'dart:async';

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
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  await testMain();
}
