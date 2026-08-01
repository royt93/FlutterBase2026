// Unit tests for isActuallyRelease() — the shared OR-with-kReleaseMode helper
// that closes the bypass a raw `if (kReleaseMode)` check has no seam against
// (see AdSafetyConfig's R12-A dryRun release guard and VipManager).
//
// kReleaseMode is always false under `flutter test`, so these tests can only
// exercise the isRelease-override branch — not a genuine release build.

import 'package:applovin_admob_sdk/src/utils/release_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to kReleaseMode (false under test) when no override given',
      () {
    expect(isActuallyRelease(), isFalse);
  });

  test('isRelease: true forces true even though kReleaseMode is false', () {
    expect(isActuallyRelease(true), isTrue);
  });

  test('isRelease: false stays false (matches kReleaseMode under test)', () {
    expect(isActuallyRelease(false), isFalse);
  });
}
