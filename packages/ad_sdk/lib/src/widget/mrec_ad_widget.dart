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

/// MREC (medium rectangle, 300x250) ad widget — provider-agnostic.
///
/// Unlike [BannerAdWidget], MREC uses a fixed native size on both providers —
/// there is no adaptive-width sizing to wire up.
///
/// Place anywhere in your screen tree:
/// ```dart
/// Column(children: [buildMrec(), ...])     // inside an AdScreenState
/// // or directly:
/// const MrecAdWidget()
/// ```
class MrecAdWidget extends StatefulWidget {
  const MrecAdWidget({super.key});

  @override
  State<MrecAdWidget> createState() => _MrecAdWidgetState();
}

class _MrecAdWidgetState extends State<MrecAdWidget> with RouteAware {
  static const String _tag = 'MrecAdWidget';

  final ValueNotifier<bool> _initStarted = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);

  ModalRoute<void>? _subscribedRoute;

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
      _initMrec(context);
    }
  }

  void _initMrec(BuildContext ctx) {
    final mgr = AdManager();
    if (!mgr.isInitialised) {
      SafeLogger.d(_tag, '_initMrec ⏭️ AdManager not initialised yet');
      return;
    }
    if (mgr.isVIPMember()) {
      SafeLogger.d(_tag, '_initMrec ⏭️ VIP');
      return;
    }
    if (!mgr.canRequestAds) {
      SafeLogger.d(_tag, '_initMrec ⏭️ consent not granted (UMP)');
      return;
    }
    if (!mgr.isConnected) {
      SafeLogger.d(_tag, '_initMrec ⏭️ offline');
      return;
    }
    if (!mgr.canLoadMrec()) {
      SafeLogger.d(_tag, '_initMrec ⏭️ cooldown');
      return;
    }
    mgr.recordMrecLoad();
    _allowed.value = true;

    if (mgr.isAdMobProvider) {
      final width = MediaQuery.of(ctx).size.width;
      mgr.loadAdmobMrecIfNeeded(width);
    } else {
      SafeLogger.d(_tag, '_initMrec [AppLovin] uses preloaded view');
    }
  }

  // ─── RouteAware hooks ────────────────────────────────────────────────────

  @override
  void didPush() {
    final mgr = AdManager();
    if (!mgr.isAdMobProvider) {
      mgr.setMrecRoutePaused(false);
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
      mgr.setMrecRoutePaused(true);
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
      mgr.setMrecRoutePaused(false);
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
    if (adapter.mrec.autoRefreshEnabled.value != enabled) {
      adapter.mrec.autoRefreshEnabled.value = enabled;
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
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) {
        if (!_allowed.value && !_initScheduled && AdManager().isInitialised) {
          _initScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _initScheduled = false;
            if (!mounted) return;
            _initMrec(context);
          });
        }
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
  static final ValueNotifier<bool> _kAlwaysFalse = ValueNotifier<bool>(false);

  // ─── AdMob ───────────────────────────────────────────────────────────────

  Widget _buildAdmob() {
    return ValueListenableBuilder<bool>(
      valueListenable: _admobIsTop,
      builder: (context, isTop, _) {
        if (!isTop) {
          return ValueListenableBuilder<Size?>(
            valueListenable: AdManager().mrecAdSize,
            builder: (context, size, _) =>
                SizedBox(height: (size?.height ?? 250) + 16),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AdManager().mrecHasError,
          builder: (context, hasError, _) {
            if (hasError) return const SizedBox.shrink();
            return ValueListenableBuilder<bool>(
              valueListenable: AdManager().mrecVisible,
              builder: (context, visible, _) {
                if (!visible) {
                  return ValueListenableBuilder<Size?>(
                    valueListenable: AdManager().mrecAdSize,
                    builder: (context, size, _) =>
                        SizedBox(height: (size?.height ?? 250) + 16),
                  );
                }
                return _MrecContainer(
                  isLoaded: AdManager().mrecIsLoaded,
                  adSize: AdManager().mrecAdSize,
                  child: () {
                    final view = AdManager().admobMrecView;
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
      valueListenable: AdManager().mrecHasError,
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();
        return ValueListenableBuilder<Object?>(
          valueListenable: AdManager().mrecAdViewId,
          builder: (context, adViewId, _) {
            if (adViewId == null) return const _ShimmerOnlyMrecContainer();
            return _MrecContainer(
              isLoaded: AdManager().mrecIsLoaded,
              adSize: AdManager().mrecAdSize,
              child: () => _AppLovinMaxMrecView(
                adViewId: adViewId as AdViewId,
                mrecId: AdManager().appLovinMrecId,
                autoRefresh: AdManager().mrecAutoRefreshEnabled,
              ),
            );
          },
        );
      },
    );
  }
}

class _MrecContainer extends StatelessWidget {
  const _MrecContainer({
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
            final h = size?.height ?? 250;
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

class _ShimmerOnlyMrecContainer extends StatelessWidget {
  const _ShimmerOnlyMrecContainer();

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
          ShimmerView(cornerRadius: 0, width: double.infinity, height: 250),
        ],
      ),
    );
  }
}

/// AppLovin only — thin wrapper around `MaxAdView` sized for MREC.
class _AppLovinMaxMrecView extends StatelessWidget {
  const _AppLovinMaxMrecView({
    required this.adViewId,
    required this.mrecId,
    required this.autoRefresh,
  });

  final AdViewId adViewId;
  final String mrecId;
  final ValueListenable<bool> autoRefresh;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: autoRefresh,
      builder: (context, refresh, _) {
        return MaxAdView(
          adUnitId: mrecId,
          adFormat: AdFormat.mrec,
          adViewId: adViewId,
          isAutoRefreshEnabled: refresh,
          listener: AdViewAdListener(
            onAdLoadedCallback: (ad) =>
                SafeLogger.d('MrecAdWidget', 'MaxAdView ✅ ${ad.networkName}'),
            onAdLoadFailedCallback: (id, err) =>
                SafeLogger.d('MrecAdWidget', 'MaxAdView ❌ ${err.code}'),
            onAdClickedCallback: (ad) {
              SafeLogger.d('MrecAdWidget', 'MaxAdView 🎯 click');
              AdSafetyConfig.recordAdClick();
              AdManager().adapter?.eventSink?.call(AdClickEvent(
                    providerTag: '[AppLovin]',
                    type: AdSlotType.mrec,
                    placement: AdPlacement.unspecified,
                  ));
            },
            onAdExpandedCallback: (ad) =>
                SafeLogger.d('MrecAdWidget', 'MaxAdView expand'),
            onAdCollapsedCallback: (ad) =>
                SafeLogger.d('MrecAdWidget', 'MaxAdView collapse'),
          ),
        );
      },
    );
  }
}
