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
/// T120 — pure description of what [applyConsentToProviders] would send to
/// each provider for a given consent + config, with no platform-channel
/// calls. Returned by [simulateConsentOutcome].
class ConsentSimulationResult {
  const ConsentSimulationResult({
    required this.appLovinHasUserConsent,
    required this.appLovinDoNotSell,
    required this.appLovinCoppaForwarded,
    required this.admobTagForChildDirectedTreatment,
    required this.admobTagForUnderAgeOfConsent,
  });

  /// What `AppLovinMAX.setHasUserConsent` would receive.
  final bool appLovinHasUserConsent;

  /// What `AppLovinMAX.setDoNotSell` would receive.
  final bool appLovinDoNotSell;

  /// Always `false` — AppLovin MAX 4.x has no API to receive the COPPA
  /// child-directed signal at all (see the warning logged below in
  /// [applyConsentToProviders]). Exposed explicitly so a simulation can't be
  /// misread as implying AppLovin ever gets this signal.
  final bool appLovinCoppaForwarded;

  /// What AdMob's `RequestConfiguration.tagForChildDirectedTreatment` would
  /// be set to: `'yes'` or `'no'`.
  final String admobTagForChildDirectedTreatment;

  /// What AdMob's `RequestConfiguration.tagForUnderAgeOfConsent` would be
  /// set to: `'yes'` or `'unspecified'` — never `'no'`, see
  /// [applyConsentToProviders]'s comment on why that axis never asserts a
  /// negative.
  final String admobTagForUnderAgeOfConsent;
}

/// The one place both [applyConsentToProviders] and [simulateConsentOutcome]
/// compute "what should each provider be told" — kept as a single pure
/// function so the simulator can never drift from the real apply path.
ConsentSimulationResult _decideConsentOutcome(AdConsent c, AdConfig? config) =>
    ConsentSimulationResult(
      appLovinHasUserConsent: c.hasUserConsent,
      appLovinDoNotSell: c.doNotSell,
      appLovinCoppaForwarded: false,
      admobTagForChildDirectedTreatment: c.isAgeRestrictedUser ? 'yes' : 'no',
      admobTagForUnderAgeOfConsent:
          config?.umpTagForUnderAgeOfConsent == true ? 'yes' : 'unspecified',
    );

/// T120 — pure, side-effect-free preview of what [applyConsentToProviders]
/// would send to AdMob/AppLovin for a hypothetical [consent] + [config], with
/// no platform-channel calls. Lets a host (or a QA compliance check) verify a
/// GDPR/CCPA/COPPA combination resolves the way they expect BEFORE building
/// onto a real device — see round-26 finding #5 for why that gap matters.
ConsentSimulationResult simulateConsentOutcome(
  AdConsent consent, {
  AdConfig? config,
}) =>
    _decideConsentOutcome(consent, config);

Future<void> applyConsentToProviders(
  AdConsent c, {
  AdConfig? config,
}) async {
  const tag = 'AdConsent';
  final outcome = _decideConsentOutcome(c, config);
  // ─── AppLovin (4.6+ uses static methods on AppLovinMAX) ──────────────────
  try {
    AppLovinMAX.setHasUserConsent(outcome.appLovinHasUserConsent);
    AppLovinMAX.setDoNotSell(outcome.appLovinDoNotSell);
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
    final testDeviceIds =
        config?.admob?.effectiveTestDeviceIds ?? const <String>[];
    final cfg = RequestConfiguration(
      // Preserve test-device registration across consent updates.
      testDeviceIds: testDeviceIds,
      tagForChildDirectedTreatment:
          outcome.admobTagForChildDirectedTreatment == 'yes'
              ? TagForChildDirectedTreatment.yes
              : TagForChildDirectedTreatment.no,
      // MJ4 (round 5 audit) — TFUA models the EEA "under age of consent"
      // concept. It used to be left unset here on the grounds that this SDK
      // exposed no flag for that axis, but it does:
      // `AdConfig.umpTagForUnderAgeOfConsent`. That value only ever reached
      // UMP's ConsentRequestParameters, so a host that declared an under-age
      // audience got the right consent form and then had every ad request go
      // out with no under-age signal on it at all — which is the half Google
      // actually requires on the request configuration.
      //
      // Only `yes` is ever asserted. Absent an explicit declaration the answer
      // stays `unspecified` rather than `no`: claiming a user is NOT under the
      // age of consent is a statement about them we have no basis for. It is
      // still never derived from `doNotSell` (CCPA) — that is a different
      // jurisdiction and a different axis, handled per-request via RDP.
      tagForUnderAgeOfConsent:
          outcome.admobTagForUnderAgeOfConsent == 'yes'
              ? TagForUnderAgeOfConsent.yes
              : TagForUnderAgeOfConsent.unspecified,
    );
    await MobileAds.instance.updateRequestConfiguration(cfg);
    SafeLogger.d(tag,
        'AdMob RequestConfiguration applied: $c (testDevices=${testDeviceIds.length})');
  } catch (e) {
    SafeLogger.w(tag, 'AdMob privacy apply failed: $e');
  }
  // Round-19 QC, BLOCKER — record it HERE, the one funnel every provider write
  // goes through, and not at the individual call sites. `ConsentManager` puts a
  // decision in its own memory BEFORE it persists and only applies to the
  // providers last, so its value runs ahead of the SDKs whenever a persist
  // throws. Anything comparing the device's own consent state against "what is
  // applied" has to compare against this, or it mistakes a decision that was
  // merely recorded for one that landed. Round 18 tracked this in `AdManager`
  // instead and so missed every caller that is not `AdManager.setConsent` —
  // `initialize()`'s own apply, and the built-in consent dialog.
  _lastAppliedToProviders = c;
}

AdConsent? _lastAppliedToProviders;

/// The last consent [applyConsentToProviders] actually pushed to the provider
/// SDKs, whoever called it — as opposed to what has merely been recorded in
/// memory. Null until the first push of this process.
AdConsent? get lastConsentAppliedToProviders => _lastAppliedToProviders;

/// Forget it. Called by `AdManager.destroy()`: the next session re-applies
/// consent to the providers from its own bootstrapped state, so a record from
/// the torn-down one says nothing about what the next will hold.
void resetLastConsentAppliedToProviders() => _lastAppliedToProviders = null;
