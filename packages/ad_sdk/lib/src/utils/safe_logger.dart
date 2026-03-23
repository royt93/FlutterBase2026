import 'package:flutter/foundation.dart';

/// Internal logger for ad_sdk. Respects AdLogLevel set by caller.
class SafeLogger {
  static bool _verbose = true;

  static void setVerbose(bool v) => _verbose = v;

  static void d(String tag, String msg) {
    if (_verbose && kDebugMode) debugPrint('roy93~ [$tag] $msg');
  }

  static void w(String tag, String msg) {
    if (kDebugMode) debugPrint('roy93~ [$tag] ⚠️ $msg');
  }

  static void e(String tag, String msg) {
    debugPrint('roy93~ [$tag] ❌ $msg');
  }
}
