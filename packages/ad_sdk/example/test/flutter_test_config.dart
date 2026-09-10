import 'dart:async';

import 'package:visibility_detector/visibility_detector.dart';

/// Global test setup for every file under `test/` (Flutter's own convention
/// for this filename — no per-file import needed).
///
/// T154 — mirrors the SDK package's own `test/flutter_test_config.dart`.
/// `VisibilityDetector` debounces its callback behind an internal `Timer`
/// (default 500ms); a test that mounts a `BannerAdWidget`/`MrecAdWidget` (both
/// use it) and tears down before that timer fires trips `flutter_test`'s own
/// "no pending timers" invariant — this hit `compliance_demo_page_test.dart`
/// pre-existingly, unrelated to this task's own native-widget change (native
/// itself does not use `VisibilityDetector` — see native_ad_widget.dart's
/// class doc comment for why). Setting this to zero is the package's own
/// documented way to make it fire synchronously, post-frame, in tests
/// instead.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  await testMain();
}
