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
/// Reads GPP section strings' custom bit-packed encoding — MSB-first bits
/// grouped into 6-bit chunks, each chunk mapped through a base64url alphabet
/// (`A-Z a-z 0-9 - _`). Per the IAB Global Privacy Platform Core Consent
/// String Specification: this is deliberately NOT standard base64 (no byte
/// alignment, no `=` padding) — it treats the whole field-concatenated
/// bitstream as one number and chops it into 6-bit digits.
class _GppBitReader {
  _GppBitReader(String section) : _bits = _decode(section);

  static const _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  final List<int> _bits;
  int _pos = 0;

  static List<int> _decode(String section) {
    final bits = <int>[];
    for (final ch in section.codeUnits) {
      final value = _alphabet.indexOf(String.fromCharCode(ch));
      if (value == -1) {
        throw FormatException('invalid GPP base64url character: $ch');
      }
      for (var b = 5; b >= 0; b--) {
        bits.add((value >> b) & 1);
      }
    }
    return bits;
  }

  void skip(int width) => _pos += width;

  int readInt(int width) {
    if (_pos + width > _bits.length) {
      throw const FormatException('GPP section string too short');
    }
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = (value << 1) | _bits[_pos++];
    }
    return value;
  }
}

class IabStorage {
  IabStorage._();

  /// IAB TCF v2 consent string, written by UMP after an EEA consent decision.
  static const String keyTcfString = 'IABTCF_TCString';

  /// IAB US Privacy ("CCPA") string, e.g. `1YYN`.
  static const String keyUsPrivacy = 'IABUSPrivacy_String';

  /// IAB Global Privacy Platform header string (the newer US-states signal).
  static const String keyGppString = 'IABGPP_HDR_GppString';

  /// The isolated GPP "US National" (MSPA) section string, written directly
  /// by CMPs that support the GPP CMP API storage spec — Section ID 7 in
  /// the IAB Global Privacy Platform registry. Reading this instead of
  /// decoding [keyGppString] avoids re-implementing the header's own
  /// Fibonacci-range section-id encoding; the CMP already isolated it.
  static const String keyGppUsNationalString = 'IABGPP_7_String';

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

  /// Test-only seam so a test can make the open step itself hang (never
  /// settle) without needing a real Android device — `Platform.isAndroid` is
  /// fixed for the process and cannot be faked in `flutter test`. See the
  /// round-32 BLOCKER test in `test/tcf_personalisation_consent_test.dart`.
  @visibleForTesting
  static Future<SharedPreferencesAsync?> Function()? debugOpenOverride;

  static Future<SharedPreferencesAsync?> _open() async {
    final override = debugOpenOverride;
    if (override != null) return override();
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
  /// The legacy string is authoritative when present — unchanged since m10.
  /// Round-33 audit (R33-02) closed the gap m10 deliberately left open: a CMP
  /// that writes *only* the newer GPP US National section (no legacy
  /// `IABUSPrivacy_String` at all, which some new-state CMPs do) used to read
  /// as "no signal" here. [_gppUsNationalOptedOut] and [_gppCaliforniaOptedOut]
  /// are consulted (in that order) only when the legacy string is entirely
  /// absent.
  ///
  /// Round-37 audit MAJOR — added [_gppCaliforniaOptedOut] (usca, section 8),
  /// [_gppUsStatesOptedOut] (all 19 remaining US state sections, 9-27), and
  /// `TargetedAdvertisingOptOut` within US National itself (see that
  /// method). This SDK does not decode the GPP header's own section-id
  /// list — it directly probes every known US privacy section's own
  /// isolated storage key instead (the CMP API storage convention every
  /// section is read through elsewhere in this class) and returns the
  /// first one with a usable signal, checked in this priority order:
  /// legacy `IABUSPrivacy_String` → US National → California → every other
  /// US state, section-ID ascending.
  static Future<bool?> usPrivacyOptedOut() async {
    final usp = await read(keyUsPrivacy);
    if (usp != null && usp.length >= 3) {
      final flag = usp[2].toUpperCase();
      if (flag == 'Y' || flag == 'N') return flag == 'Y';
    }
    final usNational = await _gppUsNationalOptedOut();
    if (usNational != null) return usNational;
    final california = await _gppCaliforniaOptedOut();
    if (california != null) return california;
    return _gppUsStatesOptedOut();
  }

  /// Reads the GPP US National (MSPA) Core Segment's `SaleOptOut` /
  /// `SharingOptOut` fields and returns `true` if either says "Opted Out".
  /// `null` when the section is absent, unparseable, or both fields are
  /// "Not Applicable" — see the MSPA US National Technical Specification's
  /// Core Segment table for the field layout this decodes:
  /// Version(6) SharingNotice(2) SaleOptOutNotice(2) SharingOptOutNotice(2)
  /// TargetedAdvertisingOptOutNotice(2) SensitiveDataProcessingOptOutNotice(2)
  /// SensitiveDataLimitUseNotice(2) SaleOptOut(2) SharingOptOut(2) — each
  /// OptOut field is `0`=Not Applicable, `1`=Opted Out, `2`=Did Not Opt Out.
  static Future<bool?> _gppUsNationalOptedOut() async {
    final section = await read(keyGppUsNationalString);
    if (section == null) return null;
    try {
      final bits = _GppBitReader(section);
      bits.skip(6 + 2 * 6); // Version + 6 Notice fields
      final saleOptOut = bits.readInt(2);
      final sharingOptOut = bits.readInt(2);
      // Round-37 audit MAJOR — verified against the IAB Tech Lab's MSPA US
      // National Technical Specification's Core Segment table
      // (TargetedAdvertisingOptOut is Int(2), immediately after
      // SharingOptOut, same 0=N/A 1=Opted Out 2=Did Not Opt Out encoding):
      // a valid opt-out expressed ONLY in this field (a CMP can set
      // Sale/Sharing to "Not Applicable" while still opting the user out of
      // targeted advertising specifically) used to be invisible here.
      final targetedAdvertisingOptOut = bits.readInt(2);
      if (saleOptOut == 1 ||
          sharingOptOut == 1 ||
          targetedAdvertisingOptOut == 1) {
        return true;
      }
      if (saleOptOut == 2 ||
          sharingOptOut == 2 ||
          targetedAdvertisingOptOut == 2) {
        return false;
      }
      return null; // all three Not Applicable — no usable signal
    } on FormatException catch (e) {
      SafeLogger.d('IabStorage', () => 'GPP USNAT parse failed: $e');
      return null;
    }
  }

  /// The isolated GPP California section string — Section ID 8. Same CMP
  /// storage-spec convention as [keyGppUsNationalString].
  static const String keyGppCaliforniaString = 'IABGPP_8_String';

  /// Reads the GPP California section's `SaleOptOut`/`SharingOptOut` fields.
  ///
  /// Round-37 audit MAJOR — a CMP that implements ONLY the California
  /// section (no US National/legacy USPrivacy string at all) used to produce
  /// no signal here. Deliberately its own decoder, not a reuse of
  /// [_gppUsNationalOptedOut]'s bit offsets: verified against the IAB Tech
  /// Lab's "GPP Extension: California Privacy" Technical Specification, and
  /// California's Core Segment is NOT the same layout as US National — it
  /// has 3 Notice fields (SaleOptOutNotice, SharingOptOutNotice,
  /// SensitiveDataLimitUseNotice), not 6, and no
  /// `TargetedAdvertisingOptOut` field at all (CCPA/CPRA folds that concept
  /// into "Sharing"). Reusing USNAT's `skip(6 + 2*6)` here would silently
  /// read the wrong bits — exactly the "mis-parsing is worse than not
  /// reading" failure this class's own design already guards against
  /// elsewhere.
  static Future<bool?> _gppCaliforniaOptedOut() async {
    final section = await read(keyGppCaliforniaString);
    if (section == null) return null;
    try {
      final bits = _GppBitReader(section);
      bits.skip(6 + 2 * 3); // Version + 3 Notice fields
      final saleOptOut = bits.readInt(2);
      final sharingOptOut = bits.readInt(2);
      if (saleOptOut == 1 || sharingOptOut == 1) return true;
      if (saleOptOut == 2 || sharingOptOut == 2) return false;
      return null;
    } on FormatException catch (e) {
      SafeLogger.d('IabStorage', () => 'GPP California parse failed: $e');
      return null;
    }
  }

  /// Round-37 audit MAJOR — the remaining 19 US state GPP sections this SDK
  /// did not read at all: Virginia(9)/Colorado(10)/Utah(11)/Connecticut(12)/
  /// Florida(13)/Montana(14)/Oregon(15)/Texas(16)/Delaware(17)/Iowa(18)/
  /// Nebraska(19)/New Hampshire(20)/New Jersey(21)/Tennessee(22)/
  /// Minnesota(23)/Maryland(24)/Indiana(25)/Kentucky(26)/Rhode Island(27).
  ///
  /// Unlike US National/California, none of these 19 has a `SharingOptOut`
  /// value field — every one of them encodes exactly `SaleOptOut(2)`
  /// immediately followed by `TargetedAdvertisingOptOut(2)`, so a single
  /// generic decoder covers all of them; only the skip-before-`SaleOptOut`
  /// differs per state.
  ///
  /// The skip amounts below are NOT derived from each state's published
  /// Technical Specification prose alone — verified empirically instead, by
  /// instantiating the IAB Tech Lab's own official reference encoder
  /// (`@iabgpp/cmpapi` npm package) for every one of these 19 states and
  /// reading its internal field list + `bitStringLength` in order. That
  /// verification caught a real discrepancy: Maryland/Indiana/Kentucky/Rhode
  /// Island's reference implementation uses a
  /// `MspaVersion/MspaCoveredTransaction/MspaMode`-prefixed segment layout,
  /// NOT the `SectionID(6)+Version(6)+...` layout their own spec's field
  /// table literally lists — reading the prose alone here would have
  /// silently decoded the wrong bits, exactly the "mis-parsing is worse
  /// than not reading" failure this class's design already guards against
  /// elsewhere.
  static const Map<String, int> _usStateSkipBits = {
    'IABGPP_9_String': 12, // Virginia
    'IABGPP_10_String': 12, // Colorado
    'IABGPP_11_String': 14, // Utah
    'IABGPP_12_String': 12, // Connecticut
    'IABGPP_13_String': 12, // Florida
    'IABGPP_14_String': 12, // Montana
    'IABGPP_15_String': 12, // Oregon
    'IABGPP_16_String': 12, // Texas
    'IABGPP_17_String': 12, // Delaware
    'IABGPP_18_String': 14, // Iowa
    'IABGPP_19_String': 12, // Nebraska
    'IABGPP_20_String': 12, // New Hampshire
    'IABGPP_21_String': 12, // New Jersey
    'IABGPP_22_String': 12, // Tennessee
    'IABGPP_23_String': 12, // Minnesota
    'IABGPP_24_String': 16, // Maryland
    'IABGPP_25_String': 16, // Indiana
    'IABGPP_26_String': 16, // Kentucky
    'IABGPP_27_String': 16, // Rhode Island
  };

  static Future<bool?> _gppUsStateSaleTargetedOptedOut(
      String key, int skipBits) async {
    final section = await read(key);
    if (section == null) return null;
    try {
      final bits = _GppBitReader(section);
      bits.skip(skipBits);
      final saleOptOut = bits.readInt(2);
      final targetedAdvertisingOptOut = bits.readInt(2);
      if (saleOptOut == 1 || targetedAdvertisingOptOut == 1) return true;
      if (saleOptOut == 2 || targetedAdvertisingOptOut == 2) return false;
      return null;
    } on FormatException catch (e) {
      SafeLogger.d('IabStorage', () => 'GPP $key parse failed: $e');
      return null;
    }
  }

  /// Checks every US state GPP section in [_usStateSkipBits] (section-ID
  /// order) and returns the first non-null signal, or `null` if none of
  /// them is present/readable.
  ///
  /// Round-38 audit fix (MINOR) — this used to `await` each of the 19
  /// sections one at a time. It runs unconditionally on every app resume
  /// (inside `_reconcileDeviceUsPrivacy()`, itself inside
  /// `_resumeAdWorkAfterConsent`'s hard 5s budget), so on a device with a
  /// slow platform channel the sequential reads could approach or exceed
  /// that budget and silently skip a refill cycle. Reading all sections
  /// concurrently removes that latency without changing the result:
  /// `Future.wait` preserves list order regardless of completion order, so
  /// "first non-null in `_usStateSkipBits`'s order wins" still holds.
  static Future<bool?> _gppUsStatesOptedOut() async {
    final entries = _usStateSkipBits.entries.toList();
    final results = await Future.wait(entries.map(
        (entry) => _gppUsStateSaleTargetedOptedOut(entry.key, entry.value)));
    for (final result in results) {
      if (result != null) return result;
    }
    return null;
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
    } catch (e) {
      // Round-32 audit, BLOCKER fix — `_open()` only ever lets `StateError`
      // escape on its own; anything else here is `.timeout(5s)` firing
      // because the open itself never settled (e.g. a wedged
      // `PackageInfo.fromPlatform()` binder call on Android cold-start).
      // That must fail closed exactly like an unreadable store below, not
      // escape uncaught — most call sites in ad_manager.dart have no
      // try/catch around this function.
      SafeLogger.w('IabStorage',
          'tcfAllowsPersonalisedAds: platform open failed — failing closed: $e');
      return false;
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
