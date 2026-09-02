import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../adapters/applovin_ad_revenue.dart';
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
/// - reacts to `TickerMode` (e.g. `Visibility(maintainState: true)`) so a
///   hidden-but-still-mounted instance also pauses/resumes
/// - delegates everything provider-specific to the active [AdProviderAdapter]
///
/// **Known gap (round-31 audit):** a bottom-nav built directly on
/// `IndexedStack` (switching `index` to show/hide tabs, with no `Route`
/// push/pop and no `TickerMode` change either) gives this widget no signal
/// at all that it went off-screen — it keeps auto-refreshing/serving ad
/// requests in the background on a hidden tab, which is a genuine AdMob/
/// AppLovin policy risk ("don't request ads that aren't visible"). If your
/// bottom nav uses `IndexedStack`, wrap each tab's content in
/// `Visibility(maintainState: true)` instead (or `TickerMode` directly) so
/// this widget's existing pause/resume logic can see the transition.
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({
    super.key,
    this.collapseAnimationDuration = const Duration(milliseconds: 250),
    this.placement = AdPlacement.unspecified,
  });

  /// T91 — how long the banner takes to animate its height when it
  /// collapses (no-fill, cooldown, VIP) or expands (a real ad becomes
  /// ready), instead of an abrupt `SizedBox.shrink()` layout jump. Pass
  /// `Duration.zero` to disable and get the old instant-jump behavior.
  final Duration collapseAnimationDuration;

  /// T107 — tags this instance for analytics/per-placement caps, same as
  /// the `placement` param on `showInterstitialAd`/`showRewardedAd`. Every
  /// `AdLoadEvent`/`AdShowEvent` this banner emits carries it.
  final AdPlacement placement;

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> with RouteAware {
  static const String _tag = 'BannerAdWidget';

  final ValueNotifier<bool> _initStarted = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);

  /// Round-29 audit (MAJOR) — the AdMob branch of [_initBanner] computes its
  /// adaptive-banner width once, from whatever [MediaQuery] reports at first
  /// mount, and [loadBannerIfNeeded] never re-requests once a banner is
  /// cached for this key — so a rotation/resize/foldable-unfold kept the
  /// stale width forever. Tracks the width the currently-loaded AdMob
  /// banner was requested at, so [didChangeDependencies] (which already
  /// fires on every `MediaQuery` change, including rotation) can tell a
  /// real resize apart from an unrelated dependency change and reload.
  double? _admobWidthPx;

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

  /// Round-31 audit fix (MAJOR) — [RouteAware] alone only fires for an
  /// actual `Route` push/pop. A bottom-nav built on `IndexedStack`/
  /// `PageView` keeps every tab's widget subtree mounted with no route
  /// change at all when switching tabs, so a banner on a hidden tab kept
  /// auto-refreshing (AppLovin) or sitting live and requesting ads
  /// (AdMob) in the background — the same "requesting ads that aren't
  /// visible" policy risk [didPushNext] exists to avoid, just reached via
  /// a different, very common navigation pattern this widget had no
  /// signal for at all. `TickerMode.of(context)` catches apps built with
  /// `Visibility(maintainState: true)` (Flutter's own "keep mounted, hide
  /// it" widget — what `CupertinoTabScaffold` uses internally for its own
  /// tabs) and `Offstage` is a common source of confusion here: despite
  /// the name it does NOT touch `TickerMode` at all (see its own doc
  /// comment — "animations continue to run"). Neither this nor `Offstage`
  /// fires for a bare `IndexedStack`, which sets no `TickerMode` of its
  /// own — that case (arguably the MOST common bottom-nav pattern) still
  /// has no widget-tree signal to key off at all. See this class's own
  /// doc comment for the documented gap and the workaround.
  bool? _lastTickerMode;

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
    // Round-31 audit fix (MAJOR) — see `_lastTickerMode`'s doc comment.
    // Routed through the existing didPushNext/didPopNext handlers so this
    // shares their exact pause/dispose and resume/reload logic rather than
    // duplicating it.
    // Round-31 audit fix (MAJOR) — see `_lastTickerMode`'s doc comment.
    // Routed through the existing didPushNext/didPopNext handlers so this
    // shares their exact pause/dispose and resume/reload logic rather than
    // duplicating it.
    final tickerMode = TickerMode.of(context);
    final lastTickerMode = _lastTickerMode;
    _lastTickerMode = tickerMode;
    if (lastTickerMode != null && lastTickerMode != tickerMode) {
      if (!tickerMode) {
        didPushNext();
      } else {
        didPopNext();
      }
    }
    if (!_initStarted.value) {
      _initStarted.value = true;
      _initBanner(context);
      return;
    }
    // Round-29 audit (MAJOR) — reload the AdMob adaptive banner when the
    // available width actually changed (rotation, split-screen, foldable
    // unfold). AppLovin is exempt: its `MaxAdView` handles resizing natively
    // (`isAdaptiveBannerEnabled: true`), and re-preloading it here would
    // just tear down a perfectly good native view for nothing.
    final mgr = AdManager();
    if (_allowed.value && mgr.isAdMobProvider) {
      final width = MediaQuery.of(context).size.width;
      if (_admobWidthPx != null && width != _admobWidthPx) {
        SafeLogger.d(_tag,
            'width changed ($_admobWidthPx → $width) — reloading AdMob adaptive banner');
        mgr.disposeBannerInstance(this);
        _allowed.value = false;
        _initBanner(context);
      }
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
      _admobWidthPx = width;
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
      // Round-32 QC (reviewer B, BLOCKER) — `setBannerRoutePaused` already
      // releases the route's own hold by name, through the adapter's ownership
      // bookkeeping. The direct write that used to sit here ran one frame after
      // EVERY mount (`RouteObserver.subscribe` calls `didPush` unconditionally)
      // and set `autoRefreshEnabled = true` over whatever else was holding it —
      // most damagingly the `fullscreen` hold a launch App Open had just taken,
      // so a MAX banner auto-refreshed underneath the fullscreen ad. The
      // adapter was rebuilt around ownership in rounds 30–31; the widget kept
      // writing the flag directly, and the widget wins because it writes last.
      mgr.setBannerRoutePaused(this, false);
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
    } else if (_admobIsTop.value) {
      _admobIsTop.value = false;
      // Round-29 audit (MAJOR) — this used to only flip `_admobIsTop`,
      // swapping the rendered native view for a same-height placeholder.
      // Google Mobile Ads' Flutter plugin exposes no runtime "pause
      // auto-refresh" API for an already-loaded `BannerAd`, unlike
      // AppLovin's `setBannerRoutePaused` above — so the cached AdMob ad
      // object kept ticking its own refresh timer, and requesting ads that
      // aren't visible is exactly the policy risk the class this mirrors
      // (`setBannerRoutePaused`) exists to avoid. Tearing the instance down
      // is the only way to actually stop that: no native object, no
      // refresh calls. `didPopNext` below requests a fresh one on return.
      SafeLogger.d(
          _tag, '📦 AdMob route away — disposing banner (no pause API)');
      mgr.disposeBannerInstance(this);
      _allowed.value = false;
    }
    super.didPushNext();
  }

  @override
  void didPopNext() {
    final mgr = AdManager();
    if (!mgr.isAdMobProvider) {
      mgr.setBannerRoutePaused(this, false);
    } else if (!_admobIsTop.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _admobIsTop.value = true;
        _initBanner(context);
      });
    }
    super.didPopNext();
  }

  @override
  void didPop() {
    if (_admobIsTop.value) _admobIsTop.value = false;
    super.didPop();
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
                placement: widget.placement,
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
    required this.placement,
  });

  final AdViewId adViewId;
  final String bannerId;
  final ValueListenable<bool> autoRefresh;
  final AdPlacement placement;

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
                    placement: placement,
                  ));
            },
            // Round-32 audit fix (MAJOR) — AppLovin's real per-impression
            // signal for this ad-view API (there is no separate pure
            // "displayed" callback here, unlike AdMob's onAdImpression).
            // Previously the adapter recorded the impression + emitted
            // revenue from onAdLoadedCallback (fill time) instead, over-
            // counting anything that filled but was never actually seen —
            // see applovin_adapter.dart's `_handleWidgetAdLoaded`.
            onAdRevenuePaidCallback: (ad) {
              SafeLogger.d('BannerAdWidget', 'MaxAdView 💰 impression');
              AdSafetyConfig.recordBannerImpression();
              final sink = AdManager().adapter?.eventSink;
              sink?.call(AdImpressionEvent(
                providerTag: '[AppLovin]',
                type: AdSlotType.banner,
                placement: placement,
              ));
              final revenue = appLovinRevenueEvent(ad,
                  type: AdSlotType.banner, placement: placement);
              if (revenue != null) sink?.call(revenue);
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
