import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Android-only options type; see this package's pubspec entry for why it has
// to be imported directly. Importing it costs nothing on iOS — a Dart import
// of a platform package is not a native dependency.
import 'package:shared_preferences_android/shared_preferences_android.dart';

import '../utils/safe_logger.dart';

/// Reads the IAB consent strings that Google UMP (and other CMPs) write to the
/// platform's own default preference store.
///
/// MJ2 + m10 (round 5 audit). This exists because reading those keys through
/// the ordinary `SharedPreferences` API silently cannot work, and did not:
///
///  * **iOS** — the legacy `SharedPreferences` implementation prefixes every
///    key with `flutter.` (`shared_preferences_foundation`'s
///    `_defaultPrefix`), so it looked for `flutter.IABTCF_TCString` while UMP
///    writes `IABTCF_TCString`. `SharedPreferencesAsync` has no prefix, which
///    is why this class uses it.
///  * **Android** — the legacy implementation reads its own private
///    `FlutterSharedPreferences` file, while UMP writes to the app's *default*
///    store (`PreferenceManager.getDefaultSharedPreferences`, i.e. the file
///    `<packageName>_preferences`). `SharedPreferencesAsync` defaults to
///    DataStore, a third location again — so the backend and file name both
///    have to be stated explicitly.
///
/// The old code did neither, so `AdManager.tcfConsentString` returned `null`
/// on every real device while its unit test passed against
/// `setMockInitialValues` — a compliance API that looked wired and was not.
///
/// Every method fails soft (returns `null`): these values are informational
/// passthrough for host apps and third-party SDKs, and both native ad SDKs
/// read the real strings themselves regardless of what this reports.
///
/// ⚠️ Verified on Android hardware. The iOS branch follows the plugin's
/// documented behaviour but has NOT been exercised on a device — CI has been
/// down since 2026-08-09, see doc/audit/audit_claude.md (MJ29).
class IabStorage {
  IabStorage._();

  /// IAB TCF v2 consent string, written by UMP after an EEA consent decision.
  static const String keyTcfString = 'IABTCF_TCString';

  /// IAB US Privacy ("CCPA") string, e.g. `1YYN`.
  static const String keyUsPrivacy = 'IABUSPrivacy_String';

  /// IAB Global Privacy Platform header string (the newer US-states signal).
  static const String keyGppString = 'IABGPP_HDR_GppString';

  static SharedPreferencesAsync? _store;
  static String? _androidFileName;

  /// Drops the cached store so a test can swap the platform implementation
  /// underneath it.
  @visibleForTesting
  static void debugResetForTest() {
    _store = null;
    _androidFileName = null;
  }

  static Future<SharedPreferencesAsync?> _open() async {
    final existing = _store;
    if (existing != null) return existing;
    try {
      if (Platform.isAndroid) {
        // The default store's file name is derived from the application id, so
        // it has to be read at runtime rather than hardcoded.
        _androidFileName ??=
            '${(await PackageInfo.fromPlatform()).packageName}_preferences';
        _store = SharedPreferencesAsync(
          options: SharedPreferencesAsyncAndroidOptions(
            backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
            originalSharedPreferencesOptions:
                AndroidSharedPreferencesStoreOptions(
              fileName: _androidFileName,
            ),
          ),
        );
      } else {
        _store = SharedPreferencesAsync();
      }
      return _store;
    } catch (e) {
      SafeLogger.w('IabStorage', 'could not open the platform store: $e');
      return null;
    }
  }

  /// Reads one IAB string, or `null` if absent/unreadable.
  static Future<String?> read(String key) async {
    try {
      final store = await _open();
      if (store == null) return null;
      // Bounded for the same reason every other platform call in this SDK is:
      // a wedged channel must not hang a caller that is only asking for
      // informational data.
      final value =
          await store.getString(key).timeout(const Duration(seconds: 5));
      return (value == null || value.isEmpty) ? null : value;
    } catch (e) {
      SafeLogger.d('IabStorage', () => 'read($key) failed: $e');
      return null;
    }
  }

  /// Whether the IAB US Privacy string says the user opted out of sale.
  ///
  /// Format is 4 characters — version, notice, opt-out, LSPA — so index 2 is
  /// the "sale opt-out" flag and `Y` means opted out. Returns `null` when no
  /// string is present (which is NOT the same as "did not opt out"), so a
  /// caller can tell "no signal" from "signal says no".
  ///
  /// m10 deliberately stops here rather than parsing GPP: a GPP payload is a
  /// base64 bundle of per-jurisdiction sections, and mis-parsing a privacy
  /// signal is worse than not reading one. [read] with [keyGppString] exposes
  /// the raw value for a host that wants to decode it properly.
  static Future<bool?> usPrivacyOptedOut() async {
    final usp = await read(keyUsPrivacy);
    if (usp == null || usp.length < 3) return null;
    final flag = usp[2].toUpperCase();
    if (flag != 'Y' && flag != 'N') return null;
    return flag == 'Y';
  }
}
