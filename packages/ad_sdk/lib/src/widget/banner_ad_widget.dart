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
  const BannerAdWidget({super.key});

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
    if (!mgr.canLoadBanner()) {
      SafeLogger.d(_tag, '_initBanner ⏭️ cooldown');
      return;
    }
    mgr.recordBannerLoad();
    _allowed.value = true;

    if (mgr.isAdMobProvider) {
      final width = MediaQuery.of(ctx).size.width;
      mgr.loadAdmobBannerIfNeeded(width);
    } else {
      SafeLogger.d(_tag, '_initBanner [AppLovin] uses preloaded view');
    }
  }

  // ─── RouteAware hooks ────────────────────────────────────────────────────

  @override
  void didPush() {
    final mgr = AdManager();
    if (!mgr.isAdMobProvider) {
      mgr.setBannerRoutePaused(false);
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
      mgr.setBannerRoutePaused(true);
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
      mgr.setBannerRoutePaused(false);
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
    if (adapter.banner.autoRefreshEnabled.value != enabled) {
      adapter.banner.autoRefreshEnabled.value = enabled;
    }
  }

  @override
  void dispose() {
    if (_subscribedRoute != null) adRouteObserver.unsubscribe(this);
    _admobIsTop.dispose();
    _initStarted.dispose();
    _allowed.dispose();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Outer subscription: initRevision — destroy → re-init (e.g. fresh init
    // completing AFTER this widget mounted) forces a retry of _initBanner
    // against the new adapter.
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
            valueListenable: AdManager().bannerAdSize,
            builder: (context, size, _) =>
                SizedBox(height: (size?.height ?? 50) + 16),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AdManager().bannerHasError,
          builder: (context, hasError, _) {
            if (hasError) return const SizedBox.shrink();
            return ValueListenableBuilder<bool>(
              valueListenable: AdManager().bannerVisible,
              builder: (context, visible, _) {
                if (!visible) {
                  return ValueListenableBuilder<Size?>(
                    valueListenable: AdManager().bannerAdSize,
                    builder: (context, size, _) =>
                        SizedBox(height: (size?.height ?? 50) + 16),
                  );
                }
                return _BannerContainer(
                  isLoaded: AdManager().bannerIsLoaded,
                  adSize: AdManager().bannerAdSize,
                  child: () {
                    final view = AdManager().admobBannerView;
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
      valueListenable: AdManager().bannerHasError,
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();
        return ValueListenableBuilder<Object?>(
          valueListenable: AdManager().bannerAdViewId,
          builder: (context, adViewId, _) {
            if (adViewId == null) return const _ShimmerOnlyContainer();
            return _BannerContainer(
              isLoaded: AdManager().bannerIsLoaded,
              adSize: AdManager().bannerAdSize,
              child: () => _AppLovinMaxAdView(
                adViewId: adViewId as AdViewId,
                bannerId: AdManager().appLovinBannerId,
                autoRefresh: AdManager().bannerAutoRefreshEnabled,
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
