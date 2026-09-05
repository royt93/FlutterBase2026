// Round-38 audit fix (MINOR): `IabStorage._gppUsStatesOptedOut()` used to
// `await` each of the 19 US-state GPP sections one at a time, inside
// `_reconcileDeviceUsPrivacy()` which runs unconditionally on every app
// resume within `_resumeAdWorkAfterConsent`'s hard 5s budget. On a device
// with a slow platform channel, 19 sequential reads could approach or
// exceed that budget and silently skip a refill cycle.
//
// Fixed to read all 19 sections concurrently via `Future.wait`. The one
// real risk in that change: `_usStateSkipBits`' iteration order is the
// precedence order ("first non-null section wins", not "whichever resolves
// first") — this must survive the switch from a sequential loop to
// `Future.wait`. Proven below with two DIFFERENT signals seeded on an
// earlier-ordered state (Virginia, id 9) and a later one (Rhode Island, id
// 27): the earlier state's signal must still win.
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
      'usPrivacyOptedOut: an earlier-ordered US state section (Virginia, '
      'id 9) still wins over a later one (Rhode Island, id 27) with the '
      'opposite signal, after switching the read loop to run concurrently',
      () async {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      // Virginia: both OptOut fields "Did Not Opt Out" → false, not null.
      'IABGPP_9_String': 'BAoAABA',
      // Rhode Island: SaleOptOut "Opted Out" → would resolve true on its
      // own — must NOT win over Virginia's earlier, non-null false.
      'IABGPP_27_String': 'BQBA',
    });

    expect(await AdManager().usPrivacyOptedOut, isFalse,
        reason: 'Virginia (checked first) has a real, non-null signal '
            '(false) — it must win regardless of what a later-ordered '
            'state, read concurrently, resolves to');
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
