import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show DebugGeography;

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

  bool get isEnabled => duration != null && duration! > Duration.zero;

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

/// Resolves a per-platform ad-unit id override, falling back to the
/// platform-agnostic id when no override applies. Exposed as a top-level
/// function (rather than a class) so tests can drive `isAndroid`/`isIos`
/// directly without mocking `dart:io`'s `Platform`.
@visibleForTesting
String resolvePlatformAdUnitId({
  required String fallback,
  required String? androidId,
  required String? iosId,
  required bool isAndroid,
  required bool isIos,
}) {
  if (isAndroid && androidId != null && androidId.isNotEmpty) return androidId;
  if (isIos && iosId != null && iosId.isNotEmpty) return iosId;
  return fallback;
}

/// Controls which App Open surfaces [AdManager] is allowed to trigger.
enum AppOpenTrigger {
  /// Both the splash App Open (`showAppOpenAd(bypassSafety: true)`) and the
  /// background→foreground resume App Open (`showAppOpenAdOnResume`) fire
  /// normally. Default — preserves pre-existing behavior.
  both,

  /// Only the background→foreground resume App Open fires; the splash App
  /// Open is skipped.
  resumeOnly,

  /// Only the splash App Open fires; the background→foreground resume App
  /// Open is skipped.
  splashOnly,
}

/// AppLovin MAX ad-unit IDs.
class AppLovinConfig {
  const AppLovinConfig({
    required this.sdkKey,
    required String bannerId,
    required String interstitialId,
    required String appOpenId,
    required String rewardedId,
    String mrecId = '',
    String nativeId = '',
    this.androidBannerId,
    this.iosBannerId,
    this.androidInterstitialId,
    this.iosInterstitialId,
    this.androidAppOpenId,
    this.iosAppOpenId,
    this.androidRewardedId,
    this.iosRewardedId,
    this.androidMrecId,
    this.iosMrecId,
    this.androidNativeId,
    this.iosNativeId,
  })  : _bannerId = bannerId,
        _interstitialId = interstitialId,
        _appOpenId = appOpenId,
        _rewardedId = rewardedId,
        _mrecId = mrecId,
        _nativeId = nativeId;

  /// AppLovin SDK key (86 chars, from `dash.applovin.com/o/account`).
  final String sdkKey;

  final String _bannerId;
  final String _interstitialId;
  final String _appOpenId;
  final String _rewardedId;
  final String _mrecId;
  final String _nativeId;

  /// Optional per-platform overrides. When unset (or empty), the
  /// platform-agnostic id passed to the constructor is used for both
  /// platforms — fully backward compatible.
  final String? androidBannerId;
  final String? iosBannerId;
  final String? androidInterstitialId;
  final String? iosInterstitialId;
  final String? androidAppOpenId;
  final String? iosAppOpenId;
  final String? androidRewardedId;
  final String? iosRewardedId;
  final String? androidMrecId;
  final String? iosMrecId;
  final String? androidNativeId;
  final String? iosNativeId;

  String get bannerId => resolvePlatformAdUnitId(
        fallback: _bannerId,
        androidId: androidBannerId,
        iosId: iosBannerId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  String get interstitialId => resolvePlatformAdUnitId(
        fallback: _interstitialId,
        androidId: androidInterstitialId,
        iosId: iosInterstitialId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  String get appOpenId => resolvePlatformAdUnitId(
        fallback: _appOpenId,
        androidId: androidAppOpenId,
        iosId: iosAppOpenId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  String get rewardedId => resolvePlatformAdUnitId(
        fallback: _rewardedId,
        androidId: androidRewardedId,
        iosId: iosRewardedId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  /// Optional — defaults to `''` (unlike [bannerId]) so existing configs stay
  /// backward compatible. Fixed 300x250 MREC ad-unit id.
  String get mrecId => resolvePlatformAdUnitId(
        fallback: _mrecId,
        androidId: androidMrecId,
        iosId: iosMrecId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  /// Optional, defaults to `''` (unlike [bannerId]) so existing configs stay
  /// backward compatible. Native ad-unit id.
  String get nativeId => resolvePlatformAdUnitId(
        fallback: _nativeId,
        androidId: androidNativeId,
        iosId: iosNativeId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );
}

/// AdMob ad-unit IDs.
class AdMobConfig {
  const AdMobConfig({
    required String bannerId,
    required String interstitialId,
    required String appOpenId,
    String rewardedId = '',
    String mrecId = '',
    String nativeId = '',
    this.testDeviceIds = const [],
    this.androidBannerId,
    this.iosBannerId,
    this.androidInterstitialId,
    this.iosInterstitialId,
    this.androidAppOpenId,
    this.iosAppOpenId,
    this.androidRewardedId,
    this.iosRewardedId,
    this.androidMrecId,
    this.iosMrecId,
    this.androidNativeId,
    this.iosNativeId,
  })  : _bannerId = bannerId,
        _interstitialId = interstitialId,
        _appOpenId = appOpenId,
        _rewardedId = rewardedId,
        _mrecId = mrecId,
        _nativeId = nativeId;

  final String _bannerId;
  final String _interstitialId;
  final String _appOpenId;
  final String _rewardedId;
  final String _mrecId;
  final String _nativeId;

  /// AdMob's hashed-GAID test-device list. Avoids accidental "real impression"
  /// counts during development.
  final List<String> testDeviceIds;

  /// Optional per-platform overrides. When unset (or empty), the
  /// platform-agnostic id passed to the constructor is used for both
  /// platforms — fully backward compatible.
  final String? androidBannerId;
  final String? iosBannerId;
  final String? androidInterstitialId;
  final String? iosInterstitialId;
  final String? androidAppOpenId;
  final String? iosAppOpenId;
  final String? androidRewardedId;
  final String? iosRewardedId;
  final String? androidMrecId;
  final String? iosMrecId;
  final String? androidNativeId;
  final String? iosNativeId;

  String get bannerId => resolvePlatformAdUnitId(
        fallback: _bannerId,
        androidId: androidBannerId,
        iosId: iosBannerId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  String get interstitialId => resolvePlatformAdUnitId(
        fallback: _interstitialId,
        androidId: androidInterstitialId,
        iosId: iosInterstitialId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  String get appOpenId => resolvePlatformAdUnitId(
        fallback: _appOpenId,
        androidId: androidAppOpenId,
        iosId: iosAppOpenId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  String get rewardedId => resolvePlatformAdUnitId(
        fallback: _rewardedId,
        androidId: androidRewardedId,
        iosId: iosRewardedId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  /// Optional — defaults to `''` (like [rewardedId]) so existing configs stay
  /// backward compatible. Fixed 300x250 MREC ad-unit id.
  String get mrecId => resolvePlatformAdUnitId(
        fallback: _mrecId,
        androidId: androidMrecId,
        iosId: iosMrecId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );

  /// Optional — defaults to `''` (like [rewardedId]) so existing configs stay
  /// backward compatible. Native ad-unit id.
  String get nativeId => resolvePlatformAdUnitId(
        fallback: _nativeId,
        androidId: androidNativeId,
        iosId: iosNativeId,
        isAndroid: Platform.isAndroid,
        isIos: Platform.isIOS,
      );
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
    this.maxVipStackDuration,
    this.splashMaxDuration = const Duration(seconds: 8),
    this.firstInstallVipGrace = FirstInstallVipGrace.auto,
    this.firstInstallVipKey = '__FIRST_INSTALL__',
    this.autoShowConsentDialog = true,
    this.consentDialogStrings = const ConsentDialogStrings(),
    this.onPrivacyPolicyTap,
    this.consentBarrierDismissible = false,
    this.consentDialogPostSplashDelay = const Duration(seconds: 1),
    this.autoRequestUmpConsent = false,
    this.umpTagForUnderAgeOfConsent = false,
    this.umpDebugGeography,
    this.umpTestIdentifiers = const [],
    this.disableAppLovinCmpFlow = true,
    this.enableCrashGuard = true,
    this.appOpenTrigger = AppOpenTrigger.both,
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

  /// Optional cap on the **total** VIP window produced by stacking
  /// (`addVip(stack: true)` / `redeemVip(stack: true)`). When set, a stacked
  /// grant never pushes the entry's expiry beyond `now + maxVipStackDuration`;
  /// the excess is clamped (the entry is still extended up to the cap). `null`
  /// (default) = uncapped.
  ///
  /// ⚠️ **This ONLY caps the `stack: true` path.** A common misreading is that
  /// this bounds VIP duration in general — it does not. A plain (non-stacking,
  /// default `stack: false`) `addVip`/`redeemVip` call grants its `duration`
  /// as an absolute `now + duration` expiry and is **never** clamped by this
  /// value, no matter how large `duration` is (e.g. the year-2099 legacy-GAID
  /// migration grant in [VipManager.load] is unaffected).
  final Duration? maxVipStackDuration;

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

  /// Handler for the "Privacy Policy" link inside the **auto-shown**
  /// consent dialog (hidden unless [ConsentDialogStrings.privacyPolicyUrl]
  /// is also set). Typically `(url) => launchUrl(Uri.parse(url))`.
  ///
  /// Only wires the automatic post-splash dialog — hosts calling
  /// [AdManager.consentManager]'s `showDialog` manually pass their own
  /// `onPrivacyPolicyTap` to that call instead.
  final void Function(String url)? onPrivacyPolicyTap;

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

  /// When `true`, [AdManager.initialize] runs Google UMP
  /// ([AdManager.requestUmpConsent]) **before** the first ad request and gates
  /// loading on `canRequestAds` — the SDK owns the whole consent flow (T01).
  ///
  /// Default `false` so hosts that already run UMP in their splash (calling
  /// [AdManager.requestUmpConsent] themselves) don't double-run it. Set `true`
  /// to let the SDK drive UMP for you.
  final bool autoRequestUmpConsent;

  /// Forwarded to UMP as `tagForUnderAgeOfConsent` when [autoRequestUmpConsent]
  /// is `true`. Set for child-directed / under-age audiences.
  final bool umpTagForUnderAgeOfConsent;

  /// Forwarded to UMP as `debugGeography` when [autoRequestUmpConsent] is
  /// `true` — lets QA simulate an EEA/UK device from any real location.
  /// `null` (default) = no debug geography override.
  final DebugGeography? umpDebugGeography;

  /// Forwarded to UMP as `testIdentifiers` when [autoRequestUmpConsent] is
  /// `true` — your test device's advertising-id hash, so Google serves the
  /// debug consent form instead of counting the device as a real user.
  /// Default `[]`.
  final List<String> umpTestIdentifiers;

  /// When `true` (default), the AppLovin adapter disables AppLovin's **own**
  /// Terms & Privacy Policy (CMP) flow so it doesn't prompt on top of Google
  /// UMP — UMP is the single source of truth and its result is forwarded to
  /// AppLovin via `setHasUserConsent`. Set `false` only if you deliberately use
  /// AppLovin's CMP instead of UMP.
  final bool disableAppLovinCmpFlow;

  // ─── Crash guard ──────────────────────────────────────────────────────────

  /// When `true` (default), [AdManager.initialize] installs a global
  /// `FlutterError.onError` + `PlatformDispatcher.instance.onError` guard
  /// (see `ad_crash_guard.dart`) that catches exceptions attributable to
  /// this SDK's own package, logs them, and recovers the affected ad slot
  /// (`AdSlot.markShowFailed`) instead of letting them crash the host app.
  /// Any previously-installed handler is chained, never replaced — and
  /// errors NOT attributable to this SDK are forwarded untouched.
  ///
  /// Set `false` if the host app already installs its own global error
  /// handler and wants to own this itself.
  final bool enableCrashGuard;

  // ─── App Open trigger ─────────────────────────────────────────────────────

  /// Which App Open surfaces [AdManager] is allowed to trigger. Default
  /// [AppOpenTrigger.both] — preserves existing behavior (splash App Open via
  /// `showAppOpenAd(bypassSafety: true)` and background→foreground resume via
  /// `showAppOpenAdOnResume()` both fire normally).
  final AppOpenTrigger appOpenTrigger;

  /// Convenience getter.
  bool get isAdMob => provider == AdProvider.admob;
}

// ═══════ Backward-compatible ad-label constants (1.x) ═══════
const String adPlsNoteEn = 'Please note: this action may display app open ads.';
const String adPlsNoteVi =
    'Xin lưu ý: hành động này có thể hiển thị quảng cáo khi mở ứng dụng.';
const String adMayAppearEn = '(Ads may appear)';
const String adMayAppearVi = '(Có thể xuất hiện quảng cáo)';
