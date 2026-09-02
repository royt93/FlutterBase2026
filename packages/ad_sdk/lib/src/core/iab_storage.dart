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

  /// Per-purpose consent bitfield, one character per TCF purpose in order:
  /// `'1'` = consented, `'0'` = not. Index 0 is Purpose 1.
  static const String keyPurposeConsents = 'IABTCF_PurposeConsents';

  /// `1` when the CMP determined GDPR applies to this user, `0` when it does
  /// not. Absent when no TCF session has ever run.
  static const String keyGdprApplies = 'IABTCF_gdprApplies';

  static SharedPreferencesAsync? _store;
  static String? _androidFileName;

  /// Drops the cached store so a test can swap the platform implementation
  /// underneath it.
  @visibleForTesting
  static void debugResetForTest() {
    _store = null;
    _androidFileName = null;
  }

  /// Builds the options that point a read at the app's DEFAULT Android
  /// preference file (`PreferenceManager.getDefaultSharedPreferences`) —
  /// the only store UMP writes IAB strings to — instead of
  /// `SharedPreferencesAsync`'s DataStore default, a different file entirely.
  ///
  /// A standalone, `@visibleForTesting` method (not inlined into [_open]) so
  /// a test can assert against the exact object production builds, instead
  /// of a hand-rolled copy that could drift from it silently — the "canary"
  /// test that did that used to pass even after `fileName` was deleted from
  /// this class (2026-08-22 audit, independent review, M-2).
  @visibleForTesting
  static SharedPreferencesAsyncAndroidOptions androidOptionsFor(
      String fileName) {
    return SharedPreferencesAsyncAndroidOptions(
      backend: SharedPreferencesAndroidBackendLibrary.SharedPreferences,
      originalSharedPreferencesOptions:
          AndroidSharedPreferencesStoreOptions(fileName: fileName),
    );
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
          options: androidOptionsFor(_androidFileName!),
        );
      } else {
        _store = SharedPreferencesAsync();
      }
      return _store;
    } on StateError {
      // Round-31 — `SharedPreferencesAsync()` throws a `StateError` when NO
      // platform implementation is registered at all. That cannot happen in
      // a real shipped app (Flutter's generated plugin registrant always
      // wires one up before any Dart code runs) — it only happens in a test
      // harness that never bothered to set one up. Let it propagate so
      // [tcfAllowsPersonalisedAds] can tell this apart from a genuine open
      // failure on a real device; [read]/[readInt] catch everything below
      // regardless, so their behaviour is unchanged.
      rethrow;
    } catch (e) {
      SafeLogger.w('IabStorage', 'could not open the platform store: $e');
      return null;
    }
  }

  /// Reads one IAB string, or `null` if absent/unreadable.
  static Future<String?> read(String key) async {
    try {
      // m1 — `_open()` itself awaits PackageInfo.fromPlatform() on Android,
      // another unbounded platform channel, so the deadline has to cover it
      // rather than only the getString below.
      final store = await _open().timeout(const Duration(seconds: 5));
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

  /// Reads one IAB integer flag, or `null` if absent/unreadable/not an int.
  static Future<int?> readInt(String key) async {
    try {
      final store = await _open().timeout(const Duration(seconds: 5));
      if (store == null) return null;
      return await store.getInt(key).timeout(const Duration(seconds: 5));
    } catch (e) {
      // A CMP that wrote this key as a String rather than an Int lands here
      // too; "no signal" is the right answer either way.
      SafeLogger.d('IabStorage', () => 'readInt($key) failed: $e');
      return null;
    }
  }

  /// Whether the recorded TCF consent actually permits **personalised** ads.
  ///
  /// Returns `null` when there is no TCF signal at all — a caller outside the
  /// EEA must not read that as a refusal.
  ///
  /// Round-6 audit, BLOCKER. The SDK used to derive `hasUserConsent` from
  /// UMP's `ConsentStatus.obtained` alone. `obtained` means only that the form
  /// was **completed** — a user who opened the EEA form and rejected every
  /// purpose gets `obtained` just the same, and `canRequestAds` can still be
  /// true because non-personalised ads remain servable. The SDK then told
  /// AppLovin `setHasUserConsent(true)` and AdMob `nonPersonalizedAds=false`,
  /// i.e. it served personalised ads to a user who had explicitly said no.
  /// That is the exact failure GDPR/DMA enforcement looks for, and the form
  /// itself is the evidence the user refused.
  ///
  /// Personalised advertising under the TCF needs *consent* (not legitimate
  /// interest) for Purpose 1 (store/access information on a device), Purpose 3
  /// (create profiles for personalised advertising) and Purpose 4 (use
  /// profiles to select personalised advertising). Anything less is
  /// non-personalised territory, so the check is all three or nothing.
  ///
  /// Deliberately does NOT parse `IABTCF_VendorConsents` for Google's vendor
  /// id: that field is a 1000+ position bitfield with a range-encoded variant,
  /// and mis-parsing it would silently downgrade every user — the same reason
  /// [usPrivacyOptedOut] stops short of decoding GPP. The purpose bitfield is
  /// the decisive signal for *personalisation* and is a plain string.
  static Future<bool?> tcfAllowsPersonalisedAds() async {
    // Round-31 audit, BLOCKER. [read]/[readInt] deliberately fail soft to
    // `null` for every other caller here (informational passthrough), but
    // that collapses two very different situations into the same value:
    // "no TCF session has ever run" (a store that opened and read fine, keys
    // simply absent — typical outside the EEA) and "the platform store is
    // broken" (opened or read threw). Every caller of this method treats a
    // `null` as "no signal, not a refusal" and defaults to `true` — so if the
    // second case is silently reported as the first, a broken store on a
    // real EEA device would revive round-6's BLOCKER (`obtained` read as
    // consent) with zero indication anything is wrong. The iOS branch of
    // this store has never been exercised on real hardware (see class doc,
    // CI down since 2026-08-09), so this distinction is not hypothetical.
    // Read directly here (bypassing [read]/[readInt]'s catch) so a thrown
    // exception can fail CLOSED instead of being laundered into "no signal".
    SharedPreferencesAsync? store;
    try {
      store = await _open().timeout(const Duration(seconds: 5));
    } on StateError {
      // No platform implementation registered at all — a test-harness
      // artifact, impossible on a real shipped app (see [_open]). Behave as
      // before: no TCF session has ever run.
      return null;
    }
    if (store == null) {
      SafeLogger.w('IabStorage',
          'tcfAllowsPersonalisedAds: platform store unreadable — failing closed');
      return false;
    }
    int? gdprApplies;
    String? purposes;
    try {
      gdprApplies = await store
          .getInt(keyGdprApplies)
          .timeout(const Duration(seconds: 5));
      final rawPurposes = await store
          .getString(keyPurposeConsents)
          .timeout(const Duration(seconds: 5));
      purposes =
          (rawPurposes == null || rawPurposes.isEmpty) ? null : rawPurposes;
    } catch (e) {
      SafeLogger.w('IabStorage',
          'tcfAllowsPersonalisedAds: platform read failed — failing closed: $e');
      return false;
    }
    // Explicitly out of GDPR scope — the purpose bitfield is not populated
    // meaningfully there, and refusing personalisation would be wrong.
    if (gdprApplies == 0) return true;

    if (gdprApplies == null && purposes == null) {
      // No TCF session has ever run on this device (typical outside the EEA).
      return null;
    }
    // GDPR applies but no purpose consents were recorded: not consented.
    if (purposes == null || purposes.length < 4) return false;
    return purposes[0] == '1' && purposes[2] == '1' && purposes[3] == '1';
  }
}
