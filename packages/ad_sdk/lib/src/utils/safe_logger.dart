import 'package:flutter/foundation.dart';

/// Internal logger for ad_sdk.
///
/// By default all logs are shown (verbose + warning + error).
/// Only [AdLogLevel.none] suppresses everything.
class SafeLogger {
  static bool _enabled = true;

  /// When false, ALL logs are suppressed (AdLogLevel.none).
  /// When true, all logs are shown (verbose, warning, error).
  static void setEnabled(bool enabled) => _enabled = enabled;

  /// Backward-compatible alias.
  static void setVerbose(bool v) => _enabled = v;

  /// Debug-level log. Always shown unless disabled.
  static void d(String tag, String msg) {
    if (_enabled) debugPrint('roy93~ [$tag] $msg');
  }

  /// Warning-level log. Always shown unless disabled.
  static void w(String tag, String msg) {
    if (_enabled) debugPrint('roy93~ [$tag] ⚠️ $msg');
  }

  /// Error-level log. Always shown unless disabled.
  /// Guarded by kDebugMode to prevent leaking SDK internals in release builds.
  static void e(String tag, String msg) {
    if (_enabled) debugPrint('roy93~ [$tag] ❌ $msg');
  }
}
