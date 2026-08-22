import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

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
    this.shown = true,
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

  /// False only when the ad was never actually displayed to the user at all
  /// (unsupported format, not ready, already showing) — as opposed to
  /// `earned: false` alone, which also covers a real display the user
  /// dismissed without earning a reward. Defaults `true` because most
  /// [RewardResult]s — including the shared [skipped] sentinel, used by both
  /// genuine no-reward dismissals and true not-shown cases — describe a real
  /// show attempt; construct with `shown: false` explicitly at the specific
  /// call sites that skip the show entirely (see
  /// AppLovinAdapter.showRewardedInterstitial, T89 — AppLovin has no
  /// Rewarded Interstitial ad format).
  final bool shown;

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

  /// T65 (phase 2) — keyed by widget instance, same pattern/rationale as
  /// [nativeSlot]. Call [disposeBannerInstance] when the owning widget
  /// unmounts.
  AdSlot bannerSlot(Object key);

  /// Every currently-tracked banner [AdSlot] (one per still-mounted
  /// [BannerAdWidget] instance). Needed for callers that must act on ALL
  /// instances without knowing their keys — e.g. [installAdCrashGuard]
  /// recovering every stuck slot after a platform crash.
  Iterable<AdSlot> get bannerSlots;

  /// T65 (phase 3) — keyed by widget instance, same pattern/rationale as
  /// [bannerSlot]. Call [disposeMrecInstance] when the owning widget
  /// unmounts.
  AdSlot mrecSlot(Object key);

  /// Every currently-tracked mrec [AdSlot] (one per still-mounted
  /// [MrecAdWidget] instance). Same rationale as [bannerSlots].
  Iterable<AdSlot> get mrecSlots;

  /// T65 (phase 1) — keyed by widget instance so multiple simultaneous
  /// [NativeAdWidget]s each get independent slot state, instead of one
  /// [AdSlot] shared (and clobbered) across every mounted widget. Created
  /// lazily on first access for a given [key]; call [disposeNativeInstance]
  /// when the owning widget unmounts.
  AdSlot nativeSlot(Object key);

  /// Every currently-tracked native [AdSlot]. Same rationale as [bannerSlots]
  /// — added for MJ23, which found [installAdCrashGuard]'s recovery pass
  /// covering banners but not mrec or native.
  Iterable<AdSlot> get nativeSlots;

  /// Banner reactive listenables for the [BannerAdWidget] tree, keyed by
  /// widget instance (see [bannerSlot]).
  BannerListenables banner(Object key);

  /// MREC reactive listenables for the [MrecAdWidget] tree.
  BannerListenables mrec(Object key);

  /// Native reactive listenables for the [NativeAdWidget] tree, keyed by
  /// widget instance (see [nativeSlot]). Only [BannerListenables.isLoaded]/
  /// [BannerListenables.hasError] are meaningful here — native ads have no
  /// adaptive size, no auto-refresh ticker, and are always visible once
  /// loaded, so [BannerListenables.adSize]/[BannerListenables.autoRefreshEnabled]/
  /// [BannerListenables.visible] are unused stub notifiers kept only for type
  /// parity with [banner]/[mrec].
  BannerListenables native(Object key);

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
  /// [consent] is the state to apply **before** the native SDK starts, not
  /// after. MJ1 (round 5 audit): [AdManager.initialize] applied consent to the
  /// providers only after this call returned, so on an ordinary cold start
  /// `AppLovinMAX.initialize(sdkKey)` ran having received no privacy flags at
  /// all — AppLovin MAX documents them as init-time settings. Only the adapter
  /// knows the right ordering for its own SDK, so it takes the state and
  /// decides; `isAgeRestrictedUser` stays for source compatibility but is
  /// redundant with `consent.isAgeRestrictedUser`.
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  });

  /// Release native resources, native listeners, and reset all slot state.
  /// Must be safe to call before [initialize], or after a previous [dispose].
  Future<void> dispose();

  /// Throw away fullscreen ads that are loaded but not yet shown, leaving
  /// their slots ready to load again.
  ///
  /// MJ6 (round 5 audit): [applyConsent] only affects *future* requests, so a
  /// user who withdrew personalisation mid-session was still shown the
  /// personalised app-open/interstitial/rewarded ads already sitting in the
  /// cache. Ad age was the only thing that could discard them. Unlike
  /// [dispose] the adapter stays usable afterwards — this is a targeted
  /// invalidation, not teardown. Must be a no-op when nothing is cached, and
  /// must never touch an ad that is currently on screen.
  Future<void> discardCachedFullscreenAds();

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

  // ─── Rewarded Interstitial (T89, AdMob only) ───────────────────────────────
  // Google's "Rewarded Interstitial" format — shown at a natural transition
  // point (e.g. between levels), not behind an explicit "watch ad" tap. No
  // AppLovin MAX equivalent ad unit type exists; AppLovinAdapter implements
  // these as documented no-ops (rewardedInterstitialSlot never leaves idle).
  // No SSV params here (unlike showRewarded) — SSV exists to let a host's
  // backend verify a DELIBERATE user action ("I watched this specific ad for
  // this specific reward"); a natural-transition ad the user didn't opt into
  // is a weaker signal for that use case, so it's left out of this first pass
  // rather than exposing a param that would be misleading to rely on.
  AdSlot get rewardedInterstitialSlot;

  Future<void> loadRewardedInterstitial();

  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  });

  // ─── Banner ────────────────────────────────────────────────────────────────
  // T65 (phase 2) — every banner method is keyed by widget instance (see
  // nativeSlot's doc for the pattern). Both providers had the identical
  // singleton bug agy found on AdMob: AppLovin's preloadWidgetAdView/adViewId
  // was also one shared id, so two simultaneous BannerAdWidgets would fight
  // over the same MaxAdView. Call disposeBannerInstance when the owning
  // widget unmounts.

  /// AppLovin: preload widget-AdView for this [key]. AdMob: no-op (banner
  /// loads on widget mount, via [loadBannerIfNeeded]).
  Future<void> preloadBanner(Object key);

  /// AdMob only: triggered when [BannerAdWidget] mounts and reports its width.
  Future<void> loadBannerIfNeeded(Object key, double widthPx);

  /// AdMob: returns the live banner widget for [key], or null if none.
  /// AppLovin: always returns null — UI side renders [MaxAdView] from
  /// [appLovinBannerId] + [appLovinBannerAdViewId].
  Widget? buildAdmobBannerView(Object key);

  /// AppLovin only: notifies the platform that [key]'s widget moved
  /// off-route so its auto-refresh should pause.
  void setBannerRoutePaused(Object key, bool paused);
  bool bannerRoutePaused(Object key);

  /// AppLovin only: ad-unit ID used by the [BannerAdWidget]'s `MaxAdView`.
  String? get appLovinBannerId;

  /// AppLovin only: ID returned by `preloadWidgetAdView` for [key]. Drives
  /// whether that instance's `MaxAdView` mounts.
  ValueListenable<Object?> appLovinBannerAdViewId(Object key);

  /// Release [key]'s banner ad/slot/listenables/adViewId. Call from
  /// [BannerAdWidget]'s `dispose()`.
  void disposeBannerInstance(Object key);

  // ─── MREC ──────────────────────────────────────────────────────────────────
  // T65 (phase 3) — every mrec method is keyed by widget instance, mirroring
  // banner (phase 2) exactly: MREC uses the same BannerListenables bundle and
  // had the identical singleton bug on both providers.

  /// AppLovin: preload widget-AdView for this [key]. AdMob: no-op (MREC
  /// loads on widget mount, via [loadMrecIfNeeded]).
  Future<void> preloadMrec(Object key);

  /// AdMob only: triggered when [MrecAdWidget] mounts and reports its width.
  /// MREC is a FIXED 300x250 size — [widthPx] is accepted for interface
  /// parity with [loadBannerIfNeeded] but ignored (no adaptive-size lookup).
  Future<void> loadMrecIfNeeded(Object key, double widthPx);

  /// AdMob: returns the live MREC widget for [key], or null if none.
  /// AppLovin: always returns null — UI side renders [MaxAdView] from
  /// [appLovinMrecId] + [appLovinMrecAdViewId].
  Widget? buildAdmobMrecView(Object key);

  /// AppLovin only: notifies the platform that [key]'s widget moved
  /// off-route so its auto-refresh should pause.
  void setMrecRoutePaused(Object key, bool paused);
  bool mrecRoutePaused(Object key);

  /// AppLovin only: ad-unit ID used by the [MrecAdWidget]'s `MaxAdView`.
  String? get appLovinMrecId;

  /// AppLovin only: ID returned by `preloadWidgetAdView` for [key]. Drives
  /// whether that instance's `MaxAdView` mounts.
  ValueListenable<Object?> appLovinMrecAdViewId(Object key);

  /// Release [key]'s mrec ad/slot/listenables/adViewId. Call from
  /// [MrecAdWidget]'s `dispose()`.
  void disposeMrecInstance(Object key);

  // ─── Native ────────────────────────────────────────────────────────────────

  /// AdMob: preload a real `NativeAd` off-screen (mirrors [preloadMrec]),
  /// keyed by widget instance (see [nativeSlot]) so each mounted
  /// [NativeAdWidget] gets its own `NativeAd`. [templateType] (T73) selects
  /// Google's built-in native template layout/size — ignored by AppLovin.
  /// AppLovin: no-op — `MaxNativeAdView` is a self-contained widget that
  /// loads on mount, unlike AppLovin's banner/mrec `MaxAdView` bridge.
  Future<void> preloadNative(Object key,
      {TemplateType templateType = TemplateType.medium});

  /// AdMob: returns the live native-ad widget for this [key] (built from the
  /// preloaded `NativeAd` + `NativeTemplateStyle`), or null if none.
  /// AppLovin: always returns null — [NativeAdWidget] builds
  /// `MaxNativeAdView` directly from [appLovinNativeId], with no
  /// adapter-level preload step or adViewId.
  Widget? buildAdmobNativeView(Object key);

  /// Release the `NativeAd`/slot/listenables for [key]. Call from
  /// [NativeAdWidget]'s `dispose()` — otherwise every mounted-then-unmounted
  /// widget instance (e.g. items scrolled out of a `ListView`) leaks its
  /// map entry for the lifetime of the adapter.
  void disposeNativeInstance(Object key);

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
