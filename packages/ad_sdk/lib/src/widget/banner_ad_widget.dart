import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../core/ad_route_observer.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'shimmer_view.dart';

/// Banner ad widget — provider-agnostic.
///
/// Place anywhere in your screen tree:
/// ```dart
/// Column(children: [buildBanner(), ...])     // inside an AdScreenState
/// // or directly:
/// const BannerAdWidget()
/// ```
///
/// Manages its own lifecycle:
/// - subscribes to [adRouteObserver] for route-aware pause/resume
/// - delegates everything provider-specific to the active [AdProviderAdapter]
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({
    super.key,
    this.collapseAnimationDuration = const Duration(milliseconds: 250),
  });

  /// T91 — how long the banner takes to animate its height when it
  /// collapses (no-fill, cooldown, VIP) or expands (a real ad becomes
  /// ready), instead of an abrupt `SizedBox.shrink()` layout jump. Pass
  /// `Duration.zero` to disable and get the old instant-jump behavior.
  final Duration collapseAnimationDuration;

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> with RouteAware {
  static const String _tag = 'BannerAdWidget';

  final ValueNotifier<bool> _initStarted = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);

  /// T14 — the [ModalRoute] this widget is currently subscribed to via
  /// [adRouteObserver]. Re-resolved every `didChangeDependencies` so a route
  /// change (e.g. this widget's subtree moves under a new route, or the
  /// enclosing route is replaced) unsubscribes the old route before
  /// subscribing the new one — otherwise RouteAware callbacks would keep
  /// firing for a route this widget no longer belongs to.
  ModalRoute<void>? _subscribedRoute;

  /// T12 — guards against stacking multiple post-frame `_initBanner` callbacks
  /// when `build` runs repeatedly (initRevision / parent rebuilds) while the
  /// banner hasn't been allowed yet. Only one callback may be pending.
  bool _initScheduled = false;

  /// AdMob only: true while this route is the top route.
  final ValueNotifier<bool> _admobIsTop = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    SafeLogger.d(_tag, 'initState');
    AdManager().canRequestAdsListenable.addListener(_onCanRequestAdsChanged);
    // M1 — withdrawing personalisation does NOT close the canRequestAds gate,
    // so the listener above never fires for it and this widget would keep
    // showing (and refreshing) an ad loaded under the old consent.
    AdManager()
        .personalisationRevision
        .addListener(_onPersonalisationWithdrawn);
  }

  /// Audit fix — consent revoke used to leave an already-loaded banner
  /// mounted and refreshing with no verified consent basis; the gate was
  /// only ever checked once, in [_initBanner], on first mount. Disposes the
  /// live instance the moment the gate closes, and re-runs [_initBanner]
  /// once it reopens.
  /// M1 — drop the live instance so the next load carries the new consent,
  /// then re-run init. Mirrors the gate-closed path below, which is the only
  /// mechanism in this widget that reliably replaces a mounted ad.
  void _onPersonalisationWithdrawn() {
    if (!mounted) return;
    final mgr = AdManager();
    SafeLogger.w(_tag,
        '🔒 personalisation withdrawn — replacing mounted banner instance');
    mgr.disposeBannerInstance(this);
    _allowed.value = false;
    if (!mgr.canRequestAds || !mgr.isInitialised || mgr.isVIPMember()) return;
    if (_initScheduled) return;
    _initScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initScheduled = false;
      if (!mounted) return;
      _initBanner(context);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _onCanRequestAdsChanged() {
    final mgr = AdManager();
    if (mgr.canRequestAds) {
      if (!_allowed.value &&
          !_initScheduled &&
          mgr.isInitialised &&
          !mgr.isVIPMember()) {
        _initScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _initScheduled = false;
          if (!mounted) return;
          _initBanner(context);
        });
        // This listener fires from AdManager's own state change, not from
        // this widget's build phase, so nothing else is guaranteed to have
        // a frame scheduled — without this, addPostFrameCallback's callback
        // can sit queued forever and the reload silently never happens.
        WidgetsBinding.instance.scheduleFrame();
      }
      return;
    }
    if (_allowed.value) {
      SafeLogger.w(_tag,
          '🔒 consent gate closed — disposing mounted banner instance');
      mgr.disposeBannerInstance(this);
      _allowed.value = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _subscribedRoute) {
      if (_subscribedRoute != null) adRouteObserver.unsubscribe(this);
      _subscribedRoute = route;
      if (route != null) {
        adRouteObserver.subscribe(this, route);
        SafeLogger.d(_tag,
            'RouteAware subscribed: ${route.settings.name ?? route.runtimeType}');
      }
    }
    if (!_initStarted.value) {
      _initStarted.value = true;
      _initBanner(context);
    }
  }

  void _initBanner(BuildContext ctx) {
    final mgr = AdManager();
    if (!mgr.isInitialised) {
      SafeLogger.d(_tag, '_initBanner ⏭️ AdManager not initialised yet');
      return;
    }
    if (mgr.isVIPMember()) {
      SafeLogger.d(_tag, '_initBanner ⏭️ VIP');
      return;
    }
    if (!mgr.canRequestAds) {
      SafeLogger.d(_tag, '_initBanner ⏭️ consent not granted (UMP)');
      return;
    }
    if (!mgr.isConnected) {
      SafeLogger.d(_tag, '_initBanner ⏭️ offline');
      return;
    }
    if (!mgr.canLoadBanner(this)) {
      SafeLogger.d(_tag, '_initBanner ⏭️ cooldown');
      return;
    }
    mgr.recordBannerLoad(this);
    _allowed.value = true;

    if (mgr.isAdMobProvider) {
      final width = MediaQuery.of(ctx).size.width;
      mgr.loadAdmobBannerIfNeeded(this, width);
    } else {
      // T65 (phase 2) — each BannerAdWidget instance now triggers its own
      // keyed preload on mount (mirrors NativeAdWidget), instead of relying
      // on a global pre-warmed view that no longer has a single owner once
      // banner supports multiple simultaneous instances.
      SafeLogger.d(_tag, '_initBanner [AppLovin] preloading own instance');
      mgr.preloadBanner(this);
    }
  }

  // ─── RouteAware hooks ────────────────────────────────────────────────────

  @override
  void didPush() {
    final mgr = AdManager();
    if (!mgr.isAdMobProvider) {
      mgr.setBannerRoutePaused(this, false);
      // Re-enable auto-refresh if a previous didPushNext paused it
      // (e.g. user pushed → popped → re-pushed quickly).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _setAppLovinAutoRefresh(true);
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _admobIsTop.value = true;
      });
    }
    super.didPush();
  }

  @override
  void didPushNext() {
    final mgr = AdManager();
    if (!mgr.isAdMobProvider) {
      mgr.setBannerRoutePaused(this, true);
      _setAppLovinAutoRefresh(false);
    } else if (_admobIsTop.value) {
      _admobIsTop.value = false;
    }
    super.didPushNext();
  }

  @override
  void didPopNext() {
    final mgr = AdManager();
    if (!mgr.isAdMobProvider) {
      mgr.setBannerRoutePaused(this, false);
      _setAppLovinAutoRefresh(true);
    } else if (!_admobIsTop.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _admobIsTop.value = true;
      });
    }
    super.didPopNext();
  }

  @override
  void didPop() {
    if (_admobIsTop.value) _admobIsTop.value = false;
    super.didPop();
  }

  void _setAppLovinAutoRefresh(bool enabled) {
    final adapter = AdManager().adapter;
    if (adapter == null) return;
    final listenables = adapter.banner(this);
    if (listenables.autoRefreshEnabled.value != enabled) {
      listenables.autoRefreshEnabled.value = enabled;
    }
  }

  @override
  void dispose() {
    AdManager().canRequestAdsListenable.removeListener(_onCanRequestAdsChanged);
    AdManager()
        .personalisationRevision
        .removeListener(_onPersonalisationWithdrawn);
    if (_subscribedRoute != null) adRouteObserver.unsubscribe(this);
    AdManager().disposeBannerInstance(this);
    _admobIsTop.dispose();
    _initStarted.dispose();
    _allowed.dispose();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // T91 — one AnimatedSize around the whole subtree covers every
    // collapse/expand transition below (VIP, gate, no-fill, cooldown, a real
    // ad becoming ready) without needing to touch each individual
    // SizedBox.shrink() site — whatever the child's intrinsic height was
    // before vs. after a rebuild, this animates the difference.
    //
    // Duration.zero skips AnimatedSize entirely rather than passing it a
    // zero-length AnimationController — the latter can complete within the
    // same layout pass and re-dirty the RenderAnimatedSize while Flutter is
    // still laying it out (a genuine framework-level re-entrant-layout
    // assertion, not something callers can work around from outside).
    if (widget.collapseAnimationDuration == Duration.zero) {
      return _buildBanner(context);
    }
    return AnimatedSize(
      duration: widget.collapseAnimationDuration,
      alignment: Alignment.topCenter,
      child: _buildBanner(context),
    );
  }

  // Outer subscription: initRevision — destroy → re-init (e.g. fresh init
  // completing AFTER this widget mounted) forces a retry of _initBanner
  // against the new adapter.
  Widget _buildBanner(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) {
        if (!_allowed.value && !_initScheduled && AdManager().isInitialised) {
          _initScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _initScheduled = false;
            if (!mounted) return;
            _initBanner(context);
          });
        }
        // Inner subscription: live VIP gate. Without this, a banner mounted
        // before VIP redemption keeps painting impressions for a paying user.
        // VipManager's notifier is recreated on destroy/reinit — re-resolve
        // each rebuild so we follow the live instance.
        final vip = AdManager().vip;
        final vipListenable = vip?.activeListenable ?? _kAlwaysFalse;
        return ValueListenableBuilder<bool>(
          valueListenable: vipListenable,
          builder: (context, isVip, _) {
            if (isVip) return const SizedBox.shrink();
            return ValueListenableBuilder<bool>(
              valueListenable: _allowed,
              builder: (context, allowed, _) {
                if (!allowed) return const SizedBox.shrink();
                final mgr = AdManager();
                if (!mgr.isInitialised) return const SizedBox.shrink();
                return mgr.isAdMobProvider ? _buildAdmob() : _buildAppLovin();
              },
            );
          },
        );
      },
    );
  }

  /// Stub used when VipManager isn't available yet (before initialize).
  /// Fixed `false` — banner shows normally.
  static final ValueNotifier<bool> _kAlwaysFalse = ValueNotifier<bool>(false);

  // ─── AdMob ───────────────────────────────────────────────────────────────

  Widget _buildAdmob() {
    return ValueListenableBuilder<bool>(
      valueListenable: _admobIsTop,
      builder: (context, isTop, _) {
        if (!isTop) {
          return ValueListenableBuilder<Size?>(
            valueListenable: AdManager().bannerAdSize(this),
            builder: (context, size, _) =>
                SizedBox(height: (size?.height ?? 50) + 16),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AdManager().bannerHasError(this),
          builder: (context, hasError, _) {
            if (hasError) return const SizedBox.shrink();
            return ValueListenableBuilder<bool>(
              valueListenable: AdManager().bannerVisible(this),
              builder: (context, visible, _) {
                if (!visible) {
                  return ValueListenableBuilder<Size?>(
                    valueListenable: AdManager().bannerAdSize(this),
                    builder: (context, size, _) =>
                        SizedBox(height: (size?.height ?? 50) + 16),
                  );
                }
                return _BannerContainer(
                  isLoaded: AdManager().bannerIsLoaded(this),
                  adSize: AdManager().bannerAdSize(this),
                  child: () {
                    final view = AdManager().admobBannerView(this);
                    return view ?? const SizedBox.shrink();
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  // ─── AppLovin ────────────────────────────────────────────────────────────

  Widget _buildAppLovin() {
    return ValueListenableBuilder<bool>(
      valueListenable: AdManager().bannerHasError(this),
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();
        return ValueListenableBuilder<Object?>(
          valueListenable: AdManager().bannerAdViewId(this),
          builder: (context, adViewId, _) {
            if (adViewId == null) return const _ShimmerOnlyContainer();
            return _BannerContainer(
              isLoaded: AdManager().bannerIsLoaded(this),
              adSize: AdManager().bannerAdSize(this),
              child: () => _AppLovinMaxAdView(
                adViewId: adViewId as AdViewId,
                bannerId: AdManager().appLovinBannerId,
                autoRefresh: AdManager().bannerAutoRefreshEnabled(this),
              ),
            );
          },
        );
      },
    );
  }
}

class _BannerContainer extends StatelessWidget {
  const _BannerContainer({
    required this.isLoaded,
    required this.adSize,
    required this.child,
  });

  final ValueListenable<bool> isLoaded;
  final ValueListenable<Size?> adSize;
  final Widget Function() child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isLoaded,
      builder: (context, loaded, _) {
        return ValueListenableBuilder<Size?>(
          valueListenable: adSize,
          builder: (context, size, _) {
            final h = size?.height ?? 50;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: loaded
                        ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
                        : EdgeInsets.zero,
                    decoration: loaded
                        ? BoxDecoration(
                            color: const Color(0xFFFCCC3C),
                            borderRadius: BorderRadius.circular(2),
                          )
                        : null,
                    child: loaded
                        ? const Text(
                            'Ad',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              height: 1.1,
                            ),
                          )
                        : const ShimmerView(
                            cornerRadius: 2, width: 20, height: 13),
                  ),
                  SizedBox(
                    width: double.infinity,
                    height: h,
                    child: loaded
                        ? child()
                        : ShimmerView(
                            cornerRadius: 0,
                            width: double.infinity,
                            height: h,
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _ShimmerOnlyContainer extends StatelessWidget {
  const _ShimmerOnlyContainer();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8),
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: ShimmerView(cornerRadius: 2, width: 20, height: 13),
          ),
          ShimmerView(cornerRadius: 0, width: double.infinity, height: 50),
        ],
      ),
    );
  }
}

/// AppLovin only — thin wrapper around `MaxAdView`. Rebuilds when
/// `autoRefresh` changes; AppLovin SDK diffs the prop without recreating
/// the native view.
class _AppLovinMaxAdView extends StatelessWidget {
  const _AppLovinMaxAdView({
    required this.adViewId,
    required this.bannerId,
    required this.autoRefresh,
  });

  final AdViewId adViewId;
  final String bannerId;
  final ValueListenable<bool> autoRefresh;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: autoRefresh,
      builder: (context, refresh, _) {
        return MaxAdView(
          adUnitId: bannerId,
          adFormat: AdFormat.banner,
          adViewId: adViewId,
          isAdaptiveBannerEnabled: true,
          isAutoRefreshEnabled: refresh,
          listener: AdViewAdListener(
            onAdLoadedCallback: (ad) =>
                SafeLogger.d('BannerAdWidget', 'MaxAdView ✅ ${ad.networkName}'),
            onAdLoadFailedCallback: (id, err) =>
                SafeLogger.d('BannerAdWidget', 'MaxAdView ❌ ${err.code}'),
            onAdClickedCallback: (ad) {
              SafeLogger.d('BannerAdWidget', 'MaxAdView 🎯 click');
              AdSafetyConfig.recordAdClick();
              // Forward to the SDK event stream via the active adapter's sink.
              AdManager().adapter?.eventSink?.call(AdClickEvent(
                    providerTag: '[AppLovin]',
                    type: AdSlotType.banner,
                    placement: AdPlacement.unspecified,
                  ));
            },
            onAdExpandedCallback: (ad) =>
                SafeLogger.d('BannerAdWidget', 'MaxAdView expand'),
            onAdCollapsedCallback: (ad) =>
                SafeLogger.d('BannerAdWidget', 'MaxAdView collapse'),
          ),
        );
      },
    );
  }
}
