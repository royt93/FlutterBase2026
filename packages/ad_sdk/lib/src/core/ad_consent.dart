import 'package:applovin_max/applovin_max.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';
import '../utils/safe_logger.dart';

/// Privacy / consent flags forwarded to both providers.
///
/// **Default is conservative** (Q18A): no consent / not age-restricted /
/// do-not-sell off → ads are served as **non-personalized** until your app
/// calls [AdManager.setConsent] with the user's actual answers (e.g. after
/// the UMP form for AdMob, or your own privacy modal for AppLovin).
///
/// ### Compliance scope handled by SDK
/// - **GDPR** (EEA): forwards `hasUserConsent` to AppLovin and AdMob `npa`
///   extra. This is a boolean only — the raw IAB TCF v2.3 TC-string is
///   **not** relayed here on purpose: AppLovin MAX SDK 12.0.0+ (this project
///   is well above that, native 13.2.0.1 / Flutter applovin_max ^4.6.4)
///   already auto-reads `IABTCF_TCString`/`IABTCF_gdprApplies`/
///   `IABTCF_AddtlConsent` straight from platform storage the moment UMP
///   writes them, so forwarding it here would be redundant. See
///   [AdManager.tcfConsentString] for the manual read-only escape hatch a
///   *third* party (outside AppLovin/AdMob) can use.
/// - **COPPA** (children): `tagForChildDirectedTreatment` (AdMob). AppLovin 4.x
///   has no equivalent API — see the runtime warning logged below when
///   [AdConsent.isAgeRestrictedUser] is true (split-provider limitation).
/// - **CCPA** (California, "do not sell"): `setDoNotSell` (AppLovin) + AdMob
///   restricted-data-processing (RDP) via the per-request `AdRequest.extras`,
///   applied in [AdMobAdapter]/[GmaBridge] — **not** `tagForUnderAgeOfConsent`,
///   which is reserved for the unrelated EEA "under age of consent" (TFUA)
///   signal and must never be derived from `doNotSell`.
///
/// ### NOT handled by SDK (caller responsibility — see README)
/// - UMP consent form (use the `umpsdk` Flutter package).
/// - iOS App Tracking Transparency prompt
///   (use `app_tracking_transparency` package).
/// - `app-ads.txt` placement on your domain.
class AdConsent {
  const AdConsent({
    this.hasUserConsent = false,
    this.isAgeRestrictedUser = false,
    this.doNotSell = false,
  });

  /// True if the user explicitly agreed to personalized ads (GDPR).
  final bool hasUserConsent;

  /// True if the app is directed to children under 13 (COPPA).
  final bool isAgeRestrictedUser;

  /// True if the user opted out of "sale" of personal data (CCPA).
  final bool doNotSell;

  /// Conservative default: no consent, no age restriction, no DNS opt-out.
  /// Yields non-personalized ads everywhere.
  static const AdConsent conservative = AdConsent();

  /// Full consent — equivalent to user accepting GDPR personalized ads.
  static const AdConsent fullyAccepted = AdConsent(hasUserConsent: true);
}

/// Apply the consent flags to both provider SDKs (idempotent).
///
/// **Personalization (npa)**: this function sets AdMob's *global*
/// `RequestConfiguration` (COPPA/age tags) and AppLovin's static privacy flags.
/// The AdMob per-request non-personalized flag (`AdRequest(nonPersonalizedAds:
/// !hasUserConsent)`, i.e. `npa=1`) is applied separately by
/// [AdMobAdapter.applyConsent], which [AdManager] calls alongside this function.
///
/// **Important**: AdMob's `updateRequestConfiguration` REPLACES the entire
/// global config — it does not merge. Call sites must therefore include
/// every field they care about, including `testDeviceIds`. Without this,
/// the test-device list registered during initialize would be wiped on the
/// first `setConsent` call, and the developer would start seeing real ads
/// (risk of policy violation).
Future<void> applyConsentToProviders(
  AdConsent c, {
  AdConfig? config,
}) async {
  const tag = 'AdConsent';
  // ─── AppLovin (4.6+ uses static methods on AppLovinMAX) ──────────────────
  try {
    AppLovinMAX.setHasUserConsent(c.hasUserConsent);
    AppLovinMAX.setDoNotSell(c.doNotSell);
    // AppLovin 4.x removed `setIsAgeRestrictedUser` — there is no API to
    // forward COPPA's child-directed signal to AppLovin. This path only
    // fires when consent changes AFTER AppLovin already initialized (e.g. a
    // mid-session setConsent call), where the only option left is to warn —
    // the SDK is already running and can't be un-initialized here. The real
    // gate (T40) is at init time: AppLovinAdapter.initialize() refuses to
    // initialize at all when isAgeRestrictedUser is already true, so this
    // branch should only ever fire for a flag flipped mid-session.
    if (c.isAgeRestrictedUser) {
      SafeLogger.w(
          tag,
          'isAgeRestrictedUser=true but AppLovin MAX 4.x has no setIsAgeRestrictedUser API — '
          'COPPA child-directed signal is NOT forwarded to AppLovin (AdMob still receives it '
          'via tagForChildDirectedTreatment). AppLovin was already initialized before this '
          'consent change — it cannot be un-initialized here; call AdManager.destroy() then '
          're-initialize if you need the init-time gate (T40) to take effect.');
    }
    SafeLogger.d(tag, 'AppLovin privacy applied: $c');
  } catch (e) {
    SafeLogger.w(tag, 'AppLovin privacy apply failed: $e');
  }

  // ─── AdMob ───────────────────────────────────────────────────────────────
  try {
    final testDeviceIds = config?.admob?.testDeviceIds ?? const <String>[];
    final cfg = RequestConfiguration(
      // Preserve test-device registration across consent updates.
      testDeviceIds: testDeviceIds,
      tagForChildDirectedTreatment: c.isAgeRestrictedUser
          ? TagForChildDirectedTreatment.yes
          : TagForChildDirectedTreatment.no,
      // NOTE: `tagForUnderAgeOfConsent` (TFUA) models the EEA "under age of
      // consent" concept — an axis this SDK does not currently expose a
      // dedicated flag for. It must NOT be derived from `doNotSell` (CCPA):
      // CCPA opt-out is handled per-request via RDP in AdMobAdapter/GmaBridge
      // instead. Leaving this unset (default `unspecified`) avoids incorrectly
      // flagging non-EEA CCPA opt-outs as EEA under-age-of-consent users.
    );
    await MobileAds.instance.updateRequestConfiguration(cfg);
    SafeLogger.d(tag,
        'AdMob RequestConfiguration applied: $c (testDevices=${testDeviceIds.length})');
  } catch (e) {
    SafeLogger.w(tag, 'AdMob privacy apply failed: $e');
  }
}
