// Canary for the one place this package reaches into a platform-implementation
// API rather than a public contract.
//
// `IabStorage` has to name `SharedPreferencesAsyncAndroidOptions` and
// `AndroidSharedPreferencesStoreOptions.fileName` to point a read at the app's
// DEFAULT preference file — the only store Google UMP writes its IAB consent
// strings to. Those types live in `shared_preferences_android`, which is a
// platform implementation: Flutter makes no compatibility promise about it, and
// the pubspec deliberately puts no upper bound on it (an upper bound would
// become a new pinning wall for every consuming app — see CLAUDE.md).
//
// So the guard is here instead. If a `shared_preferences` upgrade renames or
// reshapes any of this, these tests fail to COMPILE, which is exactly the
// signal we want. The alternative — discovering it at runtime — is precisely
// how MJ2 stayed broken for four audit rounds: the read silently returned null
// on every device while a mocked test kept passing.

import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test('the Android options API IabStorage depends on still exists', () {
    // M-2 (independent review) — this used to build its OWN options object
    // and assert on that, so deleting `fileName` from IabStorage._open()
    // entirely still left this test green: it was checking its own
    // hand-rolled copy, never production. Calling the real production
    // method means a future edit to _open() that drops or renames anything
    // here fails this test for real.
    final options = IabStorage.androidOptionsFor('pkg_preferences');

    expect(options.backend,
        SharedPreferencesAndroidBackendLibrary.SharedPreferences,
        reason: 'the SharedPreferences backend is the only one that can see '
            "the app's default preference file; DataStore (the plugin default) "
            'is a different store entirely');
    expect(options.originalSharedPreferencesOptions?.fileName,
        'pkg_preferences',
        reason: 'fileName is how the default store is addressed — losing it '
            'sends the read to the plugin-private file, which is the bug MJ2 '
            'was about');
    expect(options, isA<SharedPreferencesOptions>(),
        reason: 'must remain usable as SharedPreferencesAsync(options:)');
  });

  test('the exact IAB keys UMP writes are unchanged', () {
    // Locked deliberately: these are IAB TCF/GPP spec names, not ours. A typo
    // here reads as "no consent recorded", which is the most dangerous wrong
    // answer this class can give.
    expect(IabStorage.keyTcfString, 'IABTCF_TCString');
    expect(IabStorage.keyUsPrivacy, 'IABUSPrivacy_String');
    expect(IabStorage.keyGppString, 'IABGPP_HDR_GppString');
  });

  test('a read failure degrades to null rather than throwing', () async {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    // No entry present: the contract is a soft null, because a host asking for
    // an informational consent string must never be handed an exception.
    await expectLater(IabStorage.read(IabStorage.keyTcfString), completion(isNull));
  });
}
