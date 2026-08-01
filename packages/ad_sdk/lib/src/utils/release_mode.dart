import 'package:flutter/foundation.dart' show kReleaseMode;

/// Whether the app is actually running in a release build.
///
/// ORs the optional [isRelease] override with the real [kReleaseMode]
/// constant, so a caller (or test) can only make the check MORE strict —
/// simulating a release build while under test — never less. A genuine
/// release build always evaluates true regardless of what's passed in,
/// closing the bypass a raw `if (kReleaseMode)` check has no seam against.
bool isActuallyRelease([bool isRelease = kReleaseMode]) =>
    isRelease || kReleaseMode;
