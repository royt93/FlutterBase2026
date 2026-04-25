/// Verbosity level applied to the SDK's [SafeLogger].
///
/// Configure via [AdConfig.logLevel]:
/// - [verbose] — emit `d`, `w`, `e` (everything). Recommended for development.
/// - [warning] — emit `w`, `e` only. Quieter, still flags issues.
/// - [error] — emit `e` only. Production-safe minimum.
/// - [none] — emit nothing. The fast-path: zero log overhead.
enum AdLogLevel {
  verbose,
  warning,
  error,
  none,
}
