// T146 — a platform store that cannot be read at all used to make
// `IabStorage.usPrivacyOptedOut()` return `null`, indistinguishable from "no
// CMP has ever written a US-Privacy/GPP key" (the normal case outside
// applicable jurisdictions). Every real caller
// (`AdManager._reconcileDeviceUsPrivacy`) only acts when the result is
// `true`, so a broken store at the exact moment a user had already opted out
// silently let personalised/sold-data ads keep running.
//
// `IabStorage.tcfAllowsPersonalisedAds()` already solved this exact class of
// bug for TCF (round-31/32, see its own doc comment and
// `test/tcf_personalisation_consent_test.dart`) by reading the store directly
// and failing CLOSED on a genuine open/read failure, while still returning
// `null` for the ordinary "key simply absent" case. This file pins the same
// contract for `usPrivacyOptedOut()` (US-Privacy legacy string + every GPP
// tier it checks).

import 'dart:async';

import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Simulates the platform preference store itself being unreadable (a
/// wedged/broken channel), as opposed to reading fine and simply finding
/// every key absent — the distinction this whole test file is about.
base class _ThrowingStore extends InMemorySharedPreferencesAsync {
  _ThrowingStore() : super.empty();

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) {
    return Future<int?>.error(
        PlatformException(code: 'CHANNEL_ERROR', message: 'store is gone'));
  }

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) {
    return Future<String?>.error(
        PlatformException(code: 'CHANNEL_ERROR', message: 'store is gone'));
  }
}

/// A store that reads every key fine EXCEPT one — pins the exact gap an
/// independent `codex` re-review caught in this fix's first version: a
/// reachability probe that only reads [IabStorage.keyUsPrivacy] cannot
/// detect a failure on any of the other ~23 keys `usPrivacyOptedOut()` also
/// reads (legacy string aside, every GPP tier). [key] never appearing in
/// `legacy`/`national`/`california`/any of the 19 US state section keys
/// still had to fail the WHOLE call closed, not just be silently dropped to
/// `null` for that one tier.
base class _OneKeyThrowsStore extends InMemorySharedPreferencesAsync {
  _OneKeyThrowsStore(this._badKey) : super.empty();

  final String _badKey;

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) {
    if (key == _badKey) {
      return Future<String?>.error(PlatformException(
          code: 'CHANNEL_ERROR', message: 'this one key is gone'));
    }
    return super.getString(key, options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void seed(Map<String, Object> data) {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(data);
  }

  group('IabStorage.usPrivacyOptedOut — regression guard (unchanged cases)',
      () {
    test('no signal at all → null, NOT an opt-out', () async {
      seed({});
      expect(await IabStorage.usPrivacyOptedOut(), isNull,
          reason: 'the normal case for a jurisdiction with no CMP session — '
              'must not be conflated with a real opt-out');
    });

    test('legacy US-Privacy string says opted out → true', () async {
      seed({'IABUSPrivacy_String': '1YYY'});
      expect(await IabStorage.usPrivacyOptedOut(), isTrue);
    });

    test('legacy US-Privacy string says did not opt out → false', () async {
      seed({'IABUSPrivacy_String': '1YNY'});
      expect(await IabStorage.usPrivacyOptedOut(), isFalse);
    });
  });

  group('IabStorage.usPrivacyOptedOut — fails CLOSED on a broken store (T146)',
      () {
    test(
        'a platform read that throws is treated as an opt-out, not as '
        '"no signal"', () async {
      IabStorage.debugResetForTest();
      SharedPreferencesAsyncPlatform.instance = _ThrowingStore();

      expect(await IabStorage.usPrivacyOptedOut(), isTrue,
          reason: 'an unreadable store must never collapse into "no signal" '
              '— that is indistinguishable downstream from "did not opt '
              'out", and _reconcileDeviceUsPrivacy() only acts on `true`');
    });

    test(
        'a failure on ONE unrelated GPP key still fails the WHOLE call '
        'closed, not just that one tier', () async {
      // Every OTHER signal says "did not opt out" (false) — if the fix
      // regressed back to a probe that only checks keyUsPrivacy, this would
      // wrongly resolve to `false` instead of failing closed to `true`.
      IabStorage.debugResetForTest();
      SharedPreferencesAsyncPlatform.instance = _OneKeyThrowsStore(
          IabStorage.keyGppCaliforniaString)
        ..setString(IabStorage.keyUsPrivacy, '1YNY',
            const SharedPreferencesOptions())
        ..setString(IabStorage.keyGppUsNationalString, '',
            const SharedPreferencesOptions());

      expect(await IabStorage.usPrivacyOptedOut(), isTrue,
          reason: 'a read failure on any single GPP key must fail the whole '
              'call closed — it must never be silently dropped while every '
              'other tier is allowed to resolve normally');
    });

    test(
        'a platform store that never opens (5s deadline fires) fails CLOSED, '
        'not by hanging or throwing out of the function', () {
      fakeAsync((async) {
        IabStorage.debugResetForTest();
        IabStorage.debugOpenOverride =
            () => Completer<SharedPreferencesAsync?>().future;
        addTearDown(() => IabStorage.debugOpenOverride = null);

        bool? result;
        Object? thrown;
        IabStorage.usPrivacyOptedOut().then((r) {
          result = r;
        }, onError: (Object e) {
          thrown = e;
        });

        async.elapse(const Duration(seconds: 6));

        expect(thrown, isNull,
            reason: 'a wedged store open must fail closed, not escape as an '
                'unhandled exception');
        expect(result, isTrue,
            reason: 'same fail-closed contract as an unreadable store above');
      });
    });
  });
}
