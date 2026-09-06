// Round-38 audit fix (MINOR): `IabStorage._gppUsStatesOptedOut()` used to
// `await` each of the 19 US-state GPP sections one at a time, inside
// `_reconcileDeviceUsPrivacy()` which runs unconditionally on every app
// resume within `_resumeAdWorkAfterConsent`'s hard 5s budget. On a device
// with a slow platform channel, 19 sequential reads could approach or
// exceed that budget and silently skip a refill cycle.
//
// Fixed to read all 19 sections concurrently via `Future.wait`. This file
// proves that switch didn't change WHICH signal wins with two different
// state sections seeded at once (Virginia, id 9, and Rhode Island, id 27).
//
// Round-40 audit MAJOR (R40-A) changed WHAT "wins" means: the historical
// rule below this comment (superseded — kept only as a marker for anyone
// who finds an old reference to it) was "first non-null section, in
// `_usStateSkipBits`'s order, wins — even if that signal is `false`".
// `_gppUsStatesOptedOut()` now applies the same true-beats-false rule as
// [IabStorage.usPrivacyOptedOut]'s doc comment: `true` from ANY state wins
// over `false` from any other, regardless of iteration order. The first
// test below was rewritten for this — Round-40 audit round 5 (fifth
// independent re-review) caught that it was still asserting the pre-R40-A
// expectation and would have shipped a full test suite self-contradicting
// the very fix this round made, one file this session did not re-run after
// round 1's `_gppUsStatesOptedOut()` change (only
// `test/ad_manager_core_test.dart` was re-run directly after each
// follow-up fix — a gap in this session's own verification, not a runtime
// bug).
//
// Fixtures are the same official-reference-encoder values already verified
// correct in test/ad_manager_core_test.dart's table-driven GPP state suite.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'usPrivacyOptedOut: R40-A — a later-ordered US state section (Rhode '
      'Island, id 27) opting out still wins over an earlier one (Virginia, '
      'id 9) explicitly not opting out, read concurrently', () async {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      // Virginia: both OptOut fields "Did Not Opt Out" → false, not null.
      'IABGPP_9_String': 'BAoAABA',
      // Rhode Island: SaleOptOut "Opted Out" → true.
      'IABGPP_27_String': 'BQBA',
    });

    expect(await AdManager().usPrivacyOptedOut, isTrue,
        reason: 'R40-A: true beats false regardless of section order — '
            'Virginia\'s earlier, non-null false must not shadow Rhode '
            'Island\'s real opt-out, whichever order they resolve in '
            'under Future.wait');
  });

  test(
      'usPrivacyOptedOut: when only a later-ordered state has a signal, '
      'that signal still surfaces (concurrency did not just drop it)',
      () async {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      // Rhode Island only — every earlier state section is absent (null).
      'IABGPP_27_String': 'BQBA', // SaleOptOut Opted-Out → true
    });

    expect(await AdManager().usPrivacyOptedOut, isTrue);
  });
}
