import 'package:flutter/foundation.dart';

import '../consent/consent_dialog_strings.dart';
import '../core/ad_safety_config.dart';
import '../utils/safe_logger.dart';
import '../vip/vip_dialog_strings.dart';
import 'ad_log_level.dart';

export 'ad_log_level.dart';

/// Build-mode-aware first-install VIP grace duration.
///
/// Mirrors the [AdSafetyParams.auto] pattern: pick a sensible duration
/// based on `kDebugMode` so QA can iterate fast in debug while release
/// users get the full 24 h ad-free window.
///
/// Usage:
/// ```dart
/// AdConfig(
///   // ...
///   firstInstallVipGrace: FirstInstallVipGrace.auto,        // default
///   firstInstallVipGrace: FirstInstallVipGrace.disabled,    // never grant
///   firstInstallVipGrace: FirstInstallVipGrace.day,         // force 24 h both modes
///   firstInstallVipGrace: const FirstInstallVipGrace(Duration(hours: 12)), // custom
/// )
/// ```
class FirstInstallVipGrace {
  /// Use [duration] in both debug and release. Pass `null` (or
  /// `Duration.zero`) to disable.
  const FirstInstallVipGrace(this.duration);

  /// Effective grace duration. `null` or `Duration.zero` → no grant.
  final Duration? duration;

  /// Disable grace entirely — first launch sees ads immediately.
  static const FirstInstallVipGrace disabled = FirstInstallVipGrace(null);

  /// 30 s — fast iteration in debug builds (you can verify "after grace
  /// expires, ads return" without waiting a real 24 h).
  static const FirstInstallVipGrace debugShort =
      FirstInstallVipGrace(Duration(seconds: 30));

  /// 24 h — recommended for release builds (ad-free first session is a
  /// well-documented retention boost).
  static const FirstInstallVipGrace day =
      FirstInstallVipGrace(Duration(days: 1));

  /// Auto-pick: [debugShort] in `kDebugMode`, [day] otherwise. Default
  /// for [AdConfig.firstInstallVipGrace].
  static const FirstInstallVipGrace auto = kDebugMode ? debugShort : day;

  bool get isEnabled =>
      duration != null && duration! > Duration.zero;

  @override
  String toString() => 'FirstInstallVipGrace($duration)';
}

/// Ad provider selection.
enum AdProvider {
  /// Google AdMob (`google_mobile_ads` package).
  admob,

  /// AppLovin MAX (`applovin_max` package).
  appLovin,
}

/// AppLovin MAX ad-unit IDs.
class AppLovinConfig {
  const AppLovinConfig({
    required this.sdkKey,
    required this.bannerId,
    required this.interstitialId,
    required this.appOpenId,
    required this.rewardedId,
  });

  /// AppLovin SDK key (86 chars, from `dash.applovin.com/o/account`).
  final String sdkKey;

  final String bannerId;
  final String interstitialId;
  final String appOpenId;
  final String rewardedId;
}

/// AdMob ad-unit IDs.
class AdMobConfig {
  const AdMobConfig({
    required this.bannerId,
    required this.interstitialId,
    required this.appOpenId,
    this.rewardedId = '',
    this.testDeviceIds = const [],
  });

  final String bannerId;
  final String interstitialId;
  final String appOpenId;
  final String rewardedId;

  /// AdMob's hashed-GAID test-device list. Avoids accidental "real impression"
  /// counts during development.
  final List<String> testDeviceIds;
}

/// Master configuration. Pass to [AdManager.initialize] before `runApp`.
class AdConfig {
  const AdConfig({
    required this.provider,
    this.appLovin,
    this.admob,
    this.vipDeviceGaids = const [],
    this.loadingBufferMs = 1000,
    this.logLevel = AdLogLevel.verbose,
    this.logTagFilter,
    this.onLog,
    this.adNotReadyMessage = 'Ad not ready — please wait and try again.',
    this.adLoadingMessage = 'Loading…',
    this.safety = AdSafetyParams.auto,
    this.vipKeyValidator,
    this.vipDialogStrings = const VipDialogStrings(),
    this.splashMaxDuration = const Duration(seconds: 8),
    this.firstInstallVipGrace = FirstInstallVipGrace.auto,
    this.firstInstallVipKey = '__FIRST_INSTALL__',
    this.autoShowConsentDialog = true,
    this.consentDialogStrings = const ConsentDialogStrings(),
    this.consentBarrierDismissible = false,
    this.consentDialogPostSplashDelay = const Duration(seconds: 1),
  }) : assert(
          provider == AdProvider.appLovin ? appLovin != null : admob != null,
          'AppLovinConfig required when provider==appLovin; AdMobConfig required when provider==admob',
        );

  final AdProvider provider;
  final AppLovinConfig? appLovin;
  final AdMobConfig? admob;

  /// Legacy GAID list — auto-migrated to [VipManager] entries (year-2099 expiry)
  /// on first init. Kept for 1.x compatibility, removed in 3.0.
  final List<String> vipDeviceGaids;

  /// Visual buffer shown before a fullscreen ad — gives the SDK time to wire
  /// the native ad and prevents a perceived "freeze" UX.
  final int loadingBufferMs;

  // ─── Logging ──────────────────────────────────────────────────────────────

  final AdLogLevel logLevel;

  /// Only emit logs whose tag is in this list. `null` = emit all tags.
  final List<String>? logTagFilter;

  /// Side-channel sink for SDK logs — pipe into Crashlytics/Sentry/your logger.
  final AdLogSink? onLog;

  // ─── User-facing strings (override for localisation) ──────────────────────

  final String adNotReadyMessage;
  final String adLoadingMessage;

  // ─── Safety / fraud protection ────────────────────────────────────────────

  /// Tunable safety parameters (caps, throttle, click-rate, dryRun, ...).
  final AdSafetyParams safety;

  // ─── VIP ──────────────────────────────────────────────────────────────────

  /// Validator your app provides for VIP-key redemption. Receives the user's
  /// input, returns `true` if valid. If `null`, redeem treats every key as
  /// valid (intended for demo/test only).
  final Future<bool> Function(String key)? vipKeyValidator;

  /// Strings used by the Cupertino VIP dialog. Override to localise.
  final VipDialogStrings vipDialogStrings;

  // ─── Splash budget (Q32E) ─────────────────────────────────────────────────

  /// Maximum duration the SDK will hold the splash screen before forcing
  /// `markSplashInactive` and forwarding the navigation. Defaults to 8 s.
  final Duration splashMaxDuration;

  // ─── First-install VIP grace ──────────────────────────────────────────────

  /// On the very first SDK init for this install (tracked via SharedPreferences),
  /// auto-grant a VIP entry whose duration is taken from this object.
  /// Default: [FirstInstallVipGrace.auto] — 30 s in debug, 24 h in release.
  ///
  /// Rationale: gives the freshly-installed user an ad-free first session so
  /// they can explore the app without being immediately monetised — known to
  /// improve D1 retention. After the grace expires the entry purges itself
  /// naturally via [VipManager.purgeExpired].
  ///
  /// Pass [FirstInstallVipGrace.disabled] to skip. Cannot retroactively grant
  /// for users who already passed first-init before this config existed.
  ///
  /// Limitations:
  ///  - "First install" actually means "first SDK init on this install" —
  ///    cleared app data or reinstall looks fresh again. This is fine for
  ///    most retention-optimisation purposes.
  ///  - The grant fires once. Calling [AdManager.destroy] +
  ///    [AdManager.initialize] inside the same install does NOT re-grant.
  ///  - User can still revoke via [VipManager.revokeVip] (key is
  ///    [firstInstallVipKey]) or [VipManager.revokeAll].
  final FirstInstallVipGrace firstInstallVipGrace;

  /// VIP entry key used by the [firstInstallVipGrace] grant. Override only if
  /// you want to discriminate this entry from user-redeemed keys in your
  /// analytics. Default `__FIRST_INSTALL__`.
  final String firstInstallVipKey;

  // ─── Consent dialog ───────────────────────────────────────────────────────

  /// If true, the SDK auto-presents the Cupertino consent dialog **after the
  /// splash flow finishes** (triggered by [AdManager.markSplashInactive] +
  /// [consentDialogPostSplashDelay]). The dialog therefore lands on whatever
  /// screen the host navigates to (typically home), NOT during splash —
  /// so it doesn't compete with the splash app-open ad for user attention.
  ///
  /// Subsequent launches skip — `hasBeenAsked` is persisted. Caller can
  /// re-show anytime via `ConsentManager.instance.showDialog(...)` from a
  /// Privacy settings page.
  ///
  /// **Skipped for VIP users**: VIPs won't see ads regardless of consent
  /// flags, so prompting adds friction without benefit. Practical effect:
  /// during the 24 h first-install grace ([firstInstallVipGrace]), the
  /// dialog stays silent — it'll surface on Day 2 once VIP expires and
  /// real ads start serving. Re-checked at schedule AND fire time, so
  /// redeeming a VIP key during the 1 s post-splash delay also suppresses.
  ///
  /// Requires [AdManager.setNavigatorKey]. If no navigator context is
  /// available when the timer fires, the show is silently skipped (logged).
  ///
  /// Default `true`. Set false if you handle consent yourself or rely on
  /// Google's UMP form via [AdManager.requestUmpConsent].
  final bool autoShowConsentDialog;

  /// Strings used by the Cupertino consent dialog. Override to localise.
  /// Vietnamese pre-canned at [ConsentDialogStrings.vi].
  final ConsentDialogStrings consentDialogStrings;

  /// Whether tapping outside the auto-shown consent dialog dismisses it.
  /// Default `false` — force user to make an explicit choice. Set `true`
  /// to allow casual dismissal (treated as "Reject" — non-personalized,
  /// hasBeenAsked stays false so it'll re-prompt next launch).
  final bool consentBarrierDismissible;

  /// Delay between [AdManager.markSplashInactive] and the auto-shown
  /// consent dialog. The pause lets the splash → home transition animate
  /// out before the dialog blooms in, avoiding the visual jank of two
  /// route changes in the same frame.
  ///
  /// Default 1 s. Bump higher if your home screen has heavy initial layout
  /// (e.g., GetX controllers fetching data) and you want the dialog to wait
  /// for the first frame to settle.
  final Duration consentDialogPostSplashDelay;

  /// Convenience getter.
  bool get isAdMob => provider == AdProvider.admob;
}

// ═══════ Backward-compatible ad-label constants (1.x) ═══════
const String adPlsNoteEn = 'Please note: this action may display app open ads.';
const String adPlsNoteVi = 'Xin lưu ý: hành động này có thể hiển thị quảng cáo khi mở ứng dụng.';
const String adMayAppearEn = '(Ads may appear)';
const String adMayAppearVi = '(Có thể xuất hiện quảng cáo)';
