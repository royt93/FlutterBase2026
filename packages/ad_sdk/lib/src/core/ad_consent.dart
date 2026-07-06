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
/// - **GDPR** (EEA): forwards `hasUserConsent` to AppLovin and AdMob `npa` extra.
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
    // forward COPPA's child-directed signal to AppLovin. When the app is
    // marked age-restricted, warn loudly so integrators know AppLovin ads
    // may still be served without the COPPA flag (AdMob still receives it
    // via tagForChildDirectedTreatment below).
    if (c.isAgeRestrictedUser) {
      SafeLogger.w(
          tag,
          'isAgeRestrictedUser=true but AppLovin MAX 4.x has no setIsAgeRestrictedUser API — '
          'COPPA child-directed signal is NOT forwarded to AppLovin (AdMob still receives it '
          'via tagForChildDirectedTreatment). If AppLovin serves ads to this user, verify '
          'COPPA compliance through AppLovin dashboard-level child-directed app settings instead.');
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
