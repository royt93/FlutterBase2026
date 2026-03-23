import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../core/ad_route_observer.dart';
import '../core/ad_manager.dart';
import '../core/ad_safety_config.dart';
import '../utils/safe_logger.dart';
import 'shimmer_view.dart';

/// Banner Ad Widget — dual provider (AdMob / AppLovin MAX).
///
/// Place this anywhere in your screen layout. It handles its own
/// lifecycle, route-awareness, and shimmer loading state automatically.
///
/// ```dart
/// // In your AdScreenState:
/// Widget build(BuildContext context) => Column(
///   children: [
///     buildBanner(), // or directly: const BannerAdWidget()
///     // ... rest of content
///   ],
/// );
/// ```
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({super.key});

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> with RouteAware {
  static const String _tag = 'BannerAdWidget';

  bool _isInitStarted = false;
  bool _isBannerAllowed = false;
  bool _isRouteSubscribed = false;

  /// [AdMob only] Per-widget flag: only render AdWidget when this is the top route.
  final ValueNotifier<bool> _admobIsTopRoute = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    SafeLogger.d(_tag, 'initState');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isRouteSubscribed) {
      final route = ModalRoute.of(context);
      if (route != null) {
        _isRouteSubscribed = true;
        adRouteObserver.subscribe(this, route);
        SafeLogger.d(_tag, 'RouteAware subscribed to ${route.settings.name ?? route.runtimeType}');
      }
    }
    if (!_isInitStarted) {
      _isInitStarted = true;
      SafeLogger.d(_tag, 'didChangeDependencies → _initBanner()');
      _initBanner(context);
    }
  }

  void _initBanner(BuildContext context) {
    final adManager = AdManager();
    SafeLogger.d(_tag, '_initBanner: isVIP=${adManager.isVIPMember()}, isConnected=${adManager.isConnected}, isAdMob=${adManager.isAdMobProvider}');

    if (adManager.isVIPMember()) { SafeLogger.d(_tag, '_initBanner ⏭️ VIP device'); return; }
    if (!adManager.isConnected) { SafeLogger.d(_tag, '_initBanner ⏭️ no internet'); return; }
    if (!adManager.canLoadBanner()) { SafeLogger.d(_tag, '_initBanner ⏭️ cooldown'); return; }

    adManager.recordBannerLoad();
    _isBannerAllowed = true;
    SafeLogger.d(_tag, '_initBanner ✅ allowed, isAdMob=${adManager.isAdMobProvider}');

    if (adManager.isAdMobProvider) {
      // AdMob: trigger banner load on mount
      final width = MediaQuery.of(context).size.width;
      SafeLogger.d(_tag, '_initBanner [AdMob] loadAdmobBannerIfNeeded, width=$width');
      adManager.loadAdmobBannerIfNeeded(width);
    } else {
      // AppLovin: preload was already done in AdManager.initialize()
      SafeLogger.d(_tag, '_initBanner [AppLovin] using preloaded adViewId=${adManager.bannerAdViewId.value}');
    }
  }

  // ═══ RouteAware hooks ═══

  @override
  void didPush() {
    final adManager = AdManager();
    if (!adManager.isAdMobProvider) {
      // AppLovin: clear route-pause flag
      adManager.setBannerRoutePaused(false);
      if (adManager.bannerAdViewId.value != null && !adManager.bannerAutoRefreshEnabled.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          adManager.bannerAutoRefreshEnabled.value = true;
        });
      }
    } else {
      // AdMob: defer _admobIsTopRoute=true to next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _admobIsTopRoute.value = true;
      });
    }
    super.didPush();
  }

  @override
  void didPushNext() {
    final adManager = AdManager();
    if (!adManager.isAdMobProvider) {
      // AppLovin: pause auto-refresh
      adManager.setBannerRoutePaused(true);
      if (adManager.bannerAutoRefreshEnabled.value) {
        SafeLogger.d(_tag, 'RouteAware.didPushNext() ⏸️ [AppLovin] Banner PAUSED');
        adManager.bannerAutoRefreshEnabled.value = false;
      }
    } else if (_admobIsTopRoute.value) {
      // AdMob: hide this widget
      SafeLogger.d(_tag, 'RouteAware.didPushNext() ⏸️ [AdMob] _admobIsTopRoute=false');
      _admobIsTopRoute.value = false;
    }
    super.didPushNext();
  }

  @override
  void didPopNext() {
    final adManager = AdManager();
    if (!adManager.isAdMobProvider) {
      // AppLovin: resume auto-refresh
      adManager.setBannerRoutePaused(false);
      if (!adManager.bannerAutoRefreshEnabled.value) {
        SafeLogger.d(_tag, 'RouteAware.didPopNext() ▶️ [AppLovin] Banner RESUMED');
        adManager.bannerAutoRefreshEnabled.value = true;
      }
    } else if (!_admobIsTopRoute.value) {
      // AdMob: restore — MUST defer to next frame to avoid crash
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        SafeLogger.d(_tag, 'RouteAware.didPopNext() postFrame ▶️ [AdMob] _admobIsTopRoute=true');
        _admobIsTopRoute.value = true;
      });
    }
    super.didPopNext();
  }

  @override
  void didPop() {
    // AdMob: remove AdWidget IMMEDIATELY when this route starts popping
    // to avoid "AdWidget already in tree" crash on the screen below
    if (_admobIsTopRoute.value) {
      SafeLogger.d(_tag, 'RouteAware.didPop() ⏹️ [AdMob] _admobIsTopRoute=false');
      _admobIsTopRoute.value = false;
    }
    super.didPop();
  }

  @override
  void dispose() {
    adRouteObserver.unsubscribe(this);
    _admobIsTopRoute.dispose();
    SafeLogger.d(_tag, 'dispose() — isBannerAllowed=$_isBannerAllowed');
    // DO NOT dispose AdManager's ValueNotifiers — they are owned by the singleton
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isBannerAllowed) return const SizedBox.shrink();

    final adManager = AdManager();
    if (adManager.isAdMobProvider) {
      return _buildAdmobBanner();
    } else {
      return _buildAppLovinBanner();
    }
  }

  // ═══════════════════════════════════════════════════
  // ADMOB PATH
  // ═══════════════════════════════════════════════════
  Widget _buildAdmobBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: _admobIsTopRoute,
      builder: (context, isTopRoute, _) {
        if (!isTopRoute) {
          return ValueListenableBuilder<Size?>(
            valueListenable: AdManager().bannerAdSize,
            builder: (context, size, _) => SizedBox(height: (size?.height ?? 50) + 16),
          );
        }

        return ValueListenableBuilder<bool>(
          valueListenable: AdManager().bannerHasError,
          builder: (context, hasError, _) {
            if (hasError) return const SizedBox.shrink();

            return ValueListenableBuilder<bool>(
              valueListenable: AdManager().bannerVisible,
              builder: (context, isVisible, _) {
                if (!isVisible) {
                  return ValueListenableBuilder<Size?>(
                    valueListenable: AdManager().bannerAdSize,
                    builder: (context, size, _) => SizedBox(height: (size?.height ?? 50) + 16),
                  );
                }

                return _buildBannerContainer(
                  isLoadedNotifier: AdManager().bannerIsLoaded,
                  adSizeNotifier: AdManager().bannerAdSize,
                  bannerChild: () {
                    final ad = AdManager().admobBannerAd;
                    if (ad == null) return const SizedBox.shrink();
                    return SizedBox(
                      width: ad.size.width.toDouble(),
                      height: ad.size.height.toDouble(),
                      child: AdWidget(ad: ad),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════
  // APPLOVIN PATH
  // ═══════════════════════════════════════════════════
  Widget _buildAppLovinBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: AdManager().bannerHasError,
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();

        return ValueListenableBuilder<AdViewId?>(
          valueListenable: AdManager().bannerAdViewId,
          builder: (context, adViewId, _) {
            if (adViewId == null) return _buildShimmerContainer();

            // Get bannerId from config via the manager's internal config
            // We expose a getter for this
            return _buildBannerContainer(
              isLoadedNotifier: AdManager().bannerIsLoaded,
              adSizeNotifier: AdManager().bannerAdSize,
              bannerChild: () {
                return ValueListenableBuilder<bool>(
                  valueListenable: AdManager().bannerAutoRefreshEnabled,
                  builder: (context, autoRefresh, _) {
                    return _MaxAdViewWrapper(
                      adViewId: adViewId,
                      isAutoRefreshEnabled: autoRefresh,
                      bannerId: AdManager().appLovinBannerId,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════
  // SHARED CONTAINER
  // ═══════════════════════════════════════════════════
  Widget _buildBannerContainer({
    required ValueNotifier<bool> isLoadedNotifier,
    required ValueNotifier<Size?> adSizeNotifier,
    required Widget Function() bannerChild,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: isLoadedNotifier,
      builder: (context, isLoaded, _) {
        return ValueListenableBuilder<Size?>(
          valueListenable: adSizeNotifier,
          builder: (context, adSize, _) {
            final bannerHeight = adSize?.height ?? 50;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isLoaded)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      child: const ShimmerView(cornerRadius: 2, width: 20, height: 13),
                    )
                  else
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFCCC3C),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: const Text(
                        'Ad',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          height: 1.1,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    height: bannerHeight,
                    child: !isLoaded
                        ? ShimmerView(cornerRadius: 0, width: double.infinity, height: bannerHeight)
                        : bannerChild(),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildShimmerContainer() {
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
            child: const ShimmerView(cornerRadius: 2, width: 20, height: 13),
          ),
          const ShimmerView(cornerRadius: 0, width: double.infinity, height: 50),
        ],
      ),
    );
  }
}

/// Internal wrapper for MaxAdView to allow testability and isolation.
class _MaxAdViewWrapper extends StatelessWidget {
  final AdViewId adViewId;
  final bool isAutoRefreshEnabled;
  final String bannerId;
  static const String _tag = 'BannerAdWidget';

  const _MaxAdViewWrapper({
    required this.adViewId,
    required this.isAutoRefreshEnabled,
    required this.bannerId,
  });

  @override
  Widget build(BuildContext context) {
    SafeLogger.d(_tag, 'MaxAdView: adViewId=$adViewId, bannerId=$bannerId, isAutoRefreshEnabled=$isAutoRefreshEnabled');
    return MaxAdView(
      adUnitId: bannerId,
      adFormat: AdFormat.banner,
      adViewId: adViewId,
      isAdaptiveBannerEnabled: true,
      isAutoRefreshEnabled: isAutoRefreshEnabled,
      listener: AdViewAdListener(
        onAdLoadedCallback: (ad) => SafeLogger.d(_tag, '✅ MaxAdView onAdLoaded, network=${ad.networkName}'),
        onAdLoadFailedCallback: (id, err) => SafeLogger.d(_tag, '❌ MaxAdView onAdLoadFailed: ${err.code}'),
        onAdClickedCallback: (ad) {
          SafeLogger.d(_tag, '🎯 MaxAdView clicked');
          AdSafetyConfig.recordAdClick();
        },
        onAdExpandedCallback: (ad) => SafeLogger.d(_tag, '📀 MaxAdView expanded'),
        onAdCollapsedCallback: (ad) => SafeLogger.d(_tag, '📁 MaxAdView collapsed'),
      ),
    );
  }
}
