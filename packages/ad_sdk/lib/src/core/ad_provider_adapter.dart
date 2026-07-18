import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/ad_config.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';
import 'ad_consent.dart';

/// Result of a rewarded-ad show. Whether the user actually earned the reward
/// (true) or skipped/closed early (false).
class RewardResult {
  const RewardResult({
    required this.earned,
    this.label,
    this.amount,
    this.pendingServerConfirmation = false,
  });
  final bool earned;
  final String? label;
  final num? amount;

  /// True only when this show call supplied SSV identifying data
  /// (`ssvCustomData`/`ssvUserId` on [AdManager.showRewardedAd]) — meaning the
  /// reward postback AppLovin/AdMob sends is the host app's OWN backend's
  /// signal to treat, not this SDK's `earned` flag alone. Purely
  /// informational: this SDK does not verify anything server-side itself.
  final bool pendingServerConfirmation;

  static const RewardResult skipped = RewardResult(earned: false);
}

/// Listenables that drive [BannerAdWidget]. Every adapter owns its own set —
/// the widget rebuilds when any of these change.
class BannerListenables {
  BannerListenables({
    required this.isLoaded,
    required this.hasError,
    required this.adSize,
    required this.autoRefreshEnabled,
    required this.visible,
  });

  /// True once a banner has been successfully loaded at least once.
  final ValueNotifier<bool> isLoaded;

  /// True if the most recent banner load failed.
  final ValueNotifier<bool> hasError;

  /// Actual rendered size — used by widget to size the placeholder.
  final ValueNotifier<Size?> adSize;

  /// AppLovin only: whether the native auto-refresh ticker is on.
  /// Toggled by route lifecycle (paused while another route is on top).
  final ValueNotifier<bool> autoRefreshEnabled;

  /// AdMob only: whether to render the AdWidget tree (false during background
  /// or when this route is no longer on top).
  final ValueNotifier<bool> visible;

  /// Cleanup when adapter is disposed permanently.
  void dispose() {
    isLoaded.dispose();
    hasError.dispose();
    adSize.dispose();
    autoRefreshEnabled.dispose();
    visible.dispose();
  }
}

/// Adapter event-sink: every load/click/revenue event the adapter observes
/// is forwarded through this callback so the orchestrator can re-emit on
/// `AdManager().events`.
typedef AdEventSink = void Function(AdEvent event);

/// Provider-agnostic interface every concrete adapter (AdMob, AppLovin)
/// must implement. The orchestrator [AdManager] never references either
/// concrete plugin directly — it routes every call through this contract.
abstract class AdProviderAdapter {
  /// Set by [AdManager] before [initialize] so the adapter can emit
  /// [AdEvent]s back to the host. `null` = events dropped.
  AdEventSink? get eventSink;
  set eventSink(AdEventSink? sink);

  /// Set by [AdManager] before [initialize] to its VIP/daily-cap/consent/
  /// connectivity checks — the same gate [AdManager]'s own `load*()` methods
  /// consult. Adapters that auto-reload a fullscreen slot from an internal
  /// dismiss/fail callback (bypassing [AdManager] entirely) must consult
  /// this before calling into the native bridge. Defaults to always-true so
  /// adapters/tests that never wire it keep working.
  bool Function() get canReload;
  set canReload(bool Function() gate);

  /// Human-readable name used in logs, e.g. `'[AdMob]'`.
  String get tag;

  /// True when [initialize] has completed successfully. Until then every
  /// load/show is a no-op returning false.
  bool get isInitialised;

  /// Per-slot reactive state.
  AdSlot get appOpenSlot;
  AdSlot get interstitialSlot;
  AdSlot get rewardedSlot;
  AdSlot get bannerSlot;
  AdSlot get mrecSlot;
  AdSlot get nativeSlot;

  /// Banner reactive listenables for the [BannerAdWidget] tree.
  BannerListenables get banner;

  /// MREC reactive listenables for the [MrecAdWidget] tree.
  BannerListenables get mrec;

  /// Native reactive listenables for the [NativeAdWidget] tree. Only
  /// [BannerListenables.isLoaded]/[BannerListenables.hasError] are meaningful
  /// here — native ads have no adaptive size, no auto-refresh ticker, and are
  /// always visible once loaded, so [BannerListenables.adSize]/
  /// [BannerListenables.autoRefreshEnabled]/[BannerListenables.visible] are
  /// unused stub notifiers kept only for type parity with [banner]/[mrec].
  BannerListenables get native;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialise the underlying SDK. Returns false on failure (caller logs).
  ///
  /// [deviceGaid] is the resolved Google Advertising ID for this device,
  /// used by AppLovin to register the device as a test device in debug
  /// builds (so the dev sees test ads, not real ones — required to avoid
  /// AppLovin policy violations).
  ///
  /// [isAgeRestrictedUser] mirrors [AdConsent.isAgeRestrictedUser] known at
  /// init time (T40). AdMob honours this via `tagForChildDirectedTreatment`
  /// after init; AppLovin MAX 4.x has no equivalent runtime API and instead
  /// skips native init entirely when true — see [AppLovinAdapter.initialize].
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
  });

  /// Release native resources, native listeners, and reset all slot state.
  /// Must be safe to call before [initialize], or after a previous [dispose].
  Future<void> dispose();

  /// Apply privacy/consent state that affects **per-request** ad
  /// personalization. Called by [AdManager] whenever consent changes (init,
  /// [AdManager.setConsent], or a consent-dialog result).
  ///
  /// AdMob maps `!consent.hasUserConsent` → non-personalized ad requests
  /// (`AdRequest(nonPersonalizedAds: true)`, i.e. the `npa=1` extra) so a user
  /// who declined consent is never served personalized ads. AppLovin already
  /// forwards consent via static `AppLovinMAX` privacy APIs, so its
  /// implementation is a no-op.
  void applyConsent(AdConsent consent);

  // ─── App Open ──────────────────────────────────────────────────────────────

  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded});
  Future<void> showAppOpen({required void Function(bool dismissed) onDismiss});

  // ─── Interstitial ──────────────────────────────────────────────────────────

  Future<void> loadInterstitial();
  Future<void> showInterstitial({required void Function(bool shown) onDone});

  // ─── Rewarded ──────────────────────────────────────────────────────────────

  Future<void> loadRewarded();

  /// [ssvCustomData]/[ssvUserId] are optional Server-Side Verification (SSV)
  /// identifiers plumbed straight through to the native SDK's real SSV
  /// field (AppLovin: `custom_data` on `showRewardedAd`; AdMob:
  /// `ServerSideVerificationOptions.customData`/`.userId`). This SDK does
  /// NOT run a server or verify anything itself — see README "Server-Side
  /// Verification" section. Omit both for today's fully client-side behavior
  /// (unchanged).
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  });

  // ─── Banner ────────────────────────────────────────────────────────────────

  /// AppLovin: preload widget-AdView. AdMob: no-op (banner loads on widget mount).
  Future<void> preloadBanner();

  /// AdMob only: triggered when [BannerAdWidget] mounts and reports its width.
  Future<void> loadBannerIfNeeded(double widthPx);

  /// AdMob: returns the live banner widget, or null if none. AppLovin:
  /// always returns null — UI side renders [MaxAdView] from [appLovinBannerId]
  /// + [appLovinBannerAdViewId] notifier.
  Widget? buildAdmobBannerView();

  /// AppLovin only: notifies the platform that the user moved off-route so
  /// auto-refresh should pause.
  void setBannerRoutePaused(bool paused);
  bool get bannerRoutePaused;

  /// AppLovin only: ad-unit ID used by the [BannerAdWidget]'s `MaxAdView`.
  String? get appLovinBannerId;

  /// AppLovin only: ID returned by `preloadWidgetAdView`. Drives whether
  /// `MaxAdView` mounts.
  ValueListenable<Object?> get appLovinBannerAdViewId;

  // ─── MREC ──────────────────────────────────────────────────────────────────

  /// AppLovin: preload widget-AdView. AdMob: no-op (MREC loads on widget mount).
  Future<void> preloadMrec();

  /// AdMob only: triggered when [MrecAdWidget] mounts and reports its width.
  /// MREC is a FIXED 300x250 size — [widthPx] is accepted for interface
  /// parity with [loadBannerIfNeeded] but ignored (no adaptive-size lookup).
  Future<void> loadMrecIfNeeded(double widthPx);

  /// AdMob: returns the live MREC widget, or null if none. AppLovin: always
  /// returns null — UI side renders [MaxAdView] from [appLovinMrecId] +
  /// [appLovinMrecAdViewId] notifier.
  Widget? buildAdmobMrecView();

  /// AppLovin only: notifies the platform that the user moved off-route so
  /// auto-refresh should pause.
  void setMrecRoutePaused(bool paused);
  bool get mrecRoutePaused;

  /// AppLovin only: ad-unit ID used by the [MrecAdWidget]'s `MaxAdView`.
  String? get appLovinMrecId;

  /// AppLovin only: ID returned by `preloadWidgetAdView`. Drives whether
  /// `MaxAdView` mounts.
  ValueListenable<Object?> get appLovinMrecAdViewId;

  // ─── Native ────────────────────────────────────────────────────────────────

  /// AdMob: preload a real `NativeAd` off-screen (mirrors [preloadMrec]).
  /// AppLovin: no-op — `MaxNativeAdView` is a self-contained widget that
  /// loads on mount, unlike AppLovin's banner/mrec `MaxAdView` bridge.
  Future<void> preloadNative();

  /// AdMob: returns the live native-ad widget (built from the preloaded
  /// `NativeAd` + `NativeTemplateStyle`), or null if none. AppLovin: always
  /// returns null — [NativeAdWidget] builds `MaxNativeAdView` directly from
  /// [appLovinNativeId], with no adapter-level preload step or adViewId.
  Widget? buildAdmobNativeView();

  /// AppLovin only: ad-unit ID used directly by [NativeAdWidget]'s
  /// `MaxNativeAdView`. Unlike [appLovinBannerId]/[appLovinMrecId] there is no
  /// companion `appLovinNativeAdViewId` — native ads don't go through the
  /// `preloadWidgetAdView`/adViewId bridge those formats use.
  String? get appLovinNativeId;

  // ─── Lifecycle hooks (called by AdManager from WidgetsBindingObserver) ────

  /// Called when the host app moves to background.
  void onAppPaused();

  /// Called when the host app returns to foreground.
  void onAppResumed();
}
