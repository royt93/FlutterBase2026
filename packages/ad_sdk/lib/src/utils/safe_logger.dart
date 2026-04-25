import 'package:flutter/foundation.dart';

import '../config/ad_log_level.dart';

/// Pluggable callback signature for [SafeLogger]'s `onLog` hook.
typedef AdLogSink = void Function(AdLogLevel level, String tag, String message);

/// Internal logger used everywhere inside this SDK.
///
/// Configurable through [AdConfig]:
/// - `logLevel: AdLogLevel.{verbose|warning|error|none}` — controls what is emitted.
/// - `logTagFilter: ['AdManager', 'AdSafety']` — only emit logs whose tag is in this list (`null` = all tags).
/// - `onLog` — pipe SDK logs into Crashlytics / Sentry / your own logger.
///
/// All public methods accept either a `String` literal or a `String Function()`
/// (lazy lambda). The lambda is **only invoked** when the log would actually
/// be emitted, so expensive interpolation (`'state=${heavy()}'`) costs zero
/// CPU when the level is suppressed.
class SafeLogger {
  SafeLogger._();

  static AdLogLevel _level = AdLogLevel.verbose;
  static List<String>? _tagFilter;
  static AdLogSink? _sink;

  /// Configure all parameters at once. Called by [AdManager.initialize].
  static void configure({
    AdLogLevel level = AdLogLevel.verbose,
    List<String>? tagFilter,
    AdLogSink? onLog,
  }) {
    _level = level;
    _tagFilter = tagFilter;
    _sink = onLog;
  }

  // ─── Backward-compat shims ────────────────────────────────────────────────

  /// 1.x API: `setEnabled(true)` ≡ verbose; `setEnabled(false)` ≡ none.
  @Deprecated('Use SafeLogger.configure(level: AdLogLevel.x). Will be removed in 3.0.')
  static void setEnabled(bool enabled) {
    _level = enabled ? AdLogLevel.verbose : AdLogLevel.none;
  }

  /// 1.x alias for [setEnabled].
  @Deprecated('Use SafeLogger.configure(level: AdLogLevel.x). Will be removed in 3.0.')
  static void setVerbose(bool v) => setEnabled(v);

  // ─── Internals ────────────────────────────────────────────────────────────

  static bool _shouldLog(AdLogLevel msgLevel, String tag) {
    if (_level == AdLogLevel.none) return false;
    final passes = switch (msgLevel) {
      AdLogLevel.verbose => _level == AdLogLevel.verbose,
      AdLogLevel.warning =>
        _level == AdLogLevel.verbose || _level == AdLogLevel.warning,
      AdLogLevel.error => _level == AdLogLevel.verbose ||
          _level == AdLogLevel.warning ||
          _level == AdLogLevel.error,
      AdLogLevel.none => false,
    };
    if (!passes) return false;
    final filter = _tagFilter;
    if (filter != null && !filter.contains(tag)) return false;
    return true;
  }

  static String _resolve(Object msg) {
    if (msg is String Function()) return msg();
    return msg.toString();
  }

  // ─── Public log methods ───────────────────────────────────────────────────

  /// Verbose / debug log. Accepts `String` or `String Function()`.
  static void d(String tag, Object msg) {
    if (!_shouldLog(AdLogLevel.verbose, tag)) return;
    final s = _resolve(msg);
    debugPrint('roy93~ [$tag] $s');
    _sink?.call(AdLogLevel.verbose, tag, s);
  }

  /// Warning. Accepts `String` or `String Function()`.
  static void w(String tag, Object msg) {
    if (!_shouldLog(AdLogLevel.warning, tag)) return;
    final s = _resolve(msg);
    debugPrint('roy93~ [$tag] ⚠️ $s');
    _sink?.call(AdLogLevel.warning, tag, s);
  }

  /// Error. Accepts `String` or `String Function()`.
  static void e(String tag, Object msg) {
    if (!_shouldLog(AdLogLevel.error, tag)) return;
    final s = _resolve(msg);
    debugPrint('roy93~ [$tag] ❌ $s');
    _sink?.call(AdLogLevel.error, tag, s);
  }

  // ─── Test/debug helpers ───────────────────────────────────────────────────

  /// Current effective level (read-only).
  static AdLogLevel get level => _level;

  /// Reset to defaults (used by test setUp).
  @visibleForTesting
  static void resetForTest() {
    _level = AdLogLevel.verbose;
    _tagFilter = null;
    _sink = null;
  }
}
