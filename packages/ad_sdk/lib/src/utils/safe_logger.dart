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
/// [critical] is the one exception to both `logLevel` and `logTagFilter` — see
/// its doc for why.
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
  @Deprecated(
      'Use SafeLogger.configure(level: AdLogLevel.x). Will be removed in 3.0.')
  static void setEnabled(bool enabled) {
    _level = enabled ? AdLogLevel.verbose : AdLogLevel.none;
  }

  /// 1.x alias for [setEnabled].
  @Deprecated(
      'Use SafeLogger.configure(level: AdLogLevel.x). Will be removed in 3.0.')
  static void setVerbose(bool v) => setEnabled(v);

  // ─── Internals ────────────────────────────────────────────────────────────

  /// [bypassLevel] skips BOTH gates — the level and the tag filter — and is
  /// used only by [critical].
  ///
  /// Round-25 QC round 4 (`codex` and `claude`, both scoring it their top
  /// deduction) — `critical` used to skip [AdLogLevel.none] but still honour
  /// [_tagFilter], so a host whose filter did not list `AdManager` silently
  /// lost the "no consent flow configured" warning. That warning replaced an
  /// `assert`, which no logger configuration could suppress, so honouring the
  /// filter made the replacement *weaker* than what it replaced — on the one
  /// diagnostic with a legal consequence (an EEA/UK user served ads with no
  /// consent form). A per-tag filter is for turning down noise; there are two
  /// `critical` call sites in the whole SDK and both mean the host's own
  /// configuration is wrong.
  static bool _shouldLog(AdLogLevel msgLevel, String tag,
      {bool bypassLevel = false}) {
    if (bypassLevel) return true;
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

  /// Prints, then hands the line to the host's sink — and neither of those is
  /// allowed to throw out of a log call.
  ///
  /// Round-25 QC round 3 (`codex`, MAJOR) — `onLog` is host code, i.e. a trust
  /// boundary: an app whose Crashlytics/Sentry wrapper throws used to make
  /// EVERY `SafeLogger` call a throw site. That defeated guards that exist
  /// precisely so a failure cannot be abandoned half-way — the adapter
  /// teardown logs from inside its own `catch`, so a throwing sink there
  /// skipped the state reset and left the SDK claiming to be initialised after
  /// telling the host it had failed. A lazy message builder is guarded for the
  /// same reason: several of them interpolate adapter state, which is exactly
  /// what is broken when the interesting logs happen.
  static void _emit(AdLogLevel level, String tag, String marker, Object msg) {
    String s;
    try {
      s = _resolve(msg);
    } catch (e) {
      s = 'a log message threw while being built: $e';
    }
    debugPrint('roy93~ [$tag] $marker$s');
    final sink = _sink;
    if (sink == null) return;
    try {
      sink(level, tag, s);
    } catch (e) {
      // Reported through `debugPrint` only — routing this back through the
      // sink is the same risk again.
      debugPrint('roy93~ [SafeLogger] ⚠️ the host onLog sink threw: $e');
    }
  }

  static String _resolve(Object msg) {
    if (msg is String Function()) return msg();
    return msg.toString();
  }

  // ─── Public log methods ───────────────────────────────────────────────────

  /// Verbose / debug log. Accepts `String` or `String Function()`.
  static void d(String tag, Object msg) {
    if (!_shouldLog(AdLogLevel.verbose, tag)) return;
    _emit(AdLogLevel.verbose, tag, '', msg);
  }

  /// Warning. Accepts `String` or `String Function()`.
  static void w(String tag, Object msg) {
    if (!_shouldLog(AdLogLevel.warning, tag)) return;
    _emit(AdLogLevel.warning, tag, '⚠️ ', msg);
  }

  /// Error. Accepts `String` or `String Function()`.
  static void e(String tag, Object msg) => _e(tag, msg);

  /// Security-critical event — bypasses **both** [AdLogLevel.none] and
  /// `logTagFilter`, so no logger configuration can hide it. Used for events
  /// where staying quiet has a consequence outside the log: a release build
  /// forcing `dryRun` back off, and a config that can never gather consent.
  /// See [_shouldLog] for why the tag filter stopped applying here in 2.4.0.
  static void critical(String tag, Object msg) =>
      _e(tag, msg, bypassLevel: true);

  /// Shared `e()`/`critical()` implementation. [bypassLevel] is kept
  /// private — only [critical] may skip the `logLevel` gate; `e()` never
  /// exposes that as a public knob.
  static void _e(String tag, Object msg, {bool bypassLevel = false}) {
    if (!_shouldLog(AdLogLevel.error, tag, bypassLevel: bypassLevel)) return;
    _emit(AdLogLevel.error, tag, bypassLevel ? '🚨 ' : '❌ ', msg);
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
