import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/ad_config.dart';
import '../state/ad_event.dart';
import '../state/ad_slot.dart';

/// Result of a rewarded-ad show. Whether the user actually earned the reward
/// (true) or skipped/closed early (false).
class RewardResult {
  const RewardResult({required this.earned, this.label, this.amount});
  final bool earned;
  final String? label;
  final num? amount;

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

  /// Banner reactive listenables for the [BannerAdWidget] tree.
  BannerListenables get banner;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initialise the underlying SDK. Returns false on failure (caller logs).
  ///
  /// [deviceGaid] is the resolved Google Advertising ID for this device,
  /// used by AppLovin to register the device as a test device in debug
  /// builds (so the dev sees test ads, not real ones — required to avoid
  /// AppLovin policy violations).
  Future<bool> initialize(AdConfig config, {String deviceGaid = ''});

  /// Release native resources, native listeners, and reset all slot state.
  /// Must be safe to call before [initialize], or after a previous [dispose].
  Future<void> dispose();

  // ─── App Open ──────────────────────────────────────────────────────────────

  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded});
  Future<void> showAppOpen({required void Function(bool dismissed) onDismiss});

  // ─── Interstitial ──────────────────────────────────────────────────────────

  Future<void> loadInterstitial();
  Future<void> showInterstitial({required void Function(bool shown) onDone});

  // ─── Rewarded ──────────────────────────────────────────────────────────────

  Future<void> loadRewarded();
  Future<void> showRewarded({required void Function(RewardResult result) onDone});

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

  // ─── Lifecycle hooks (called by AdManager from WidgetsBindingObserver) ────

  /// Called when the host app moves to background.
  void onAppPaused();

  /// Called when the host app returns to foreground.
  void onAppResumed();
}
