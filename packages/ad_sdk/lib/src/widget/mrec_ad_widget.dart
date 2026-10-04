import 'dart:async';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../adapters/applovin_ad_revenue.dart';
import '../compliance/ad_flight_recorder.dart';
import '../core/ad_manager.dart';
import '../core/ad_route_observer.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'banner_ad_widget.dart' show HouseAdItem, HouseAdSlot;
import 'inline_ad_controller.dart';
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
///
/// See [BannerAdWidget]'s doc comment for the `TickerMode`/`IndexedStack`
/// visibility notes — this widget follows the identical pattern.
class MrecAdWidget extends StatefulWidget {
  const MrecAdWidget({
    super.key,
    this.placement = AdPlacement.unspecified,
    this.active,
    this.controller,
    this.houseAd,
    this.houseAdDelay = const Duration(seconds: 10),
  }) : assert(
          active == null || controller == null,
          'Pass either active or controller, not both — controller owns '
          'pause/resume once attached.',
        );

  /// T107 — tags this instance for analytics/per-placement caps, same as
  /// the `placement` param on `showInterstitialAd`/`showRewardedAd`.
  final AdPlacement placement;

  /// Manual visibility override — see `BannerAdWidget.active`'s doc comment;
  /// this widget follows the identical pattern.
  final bool? active;

  /// T201 — imperative refresh/pause/resume/status handle for this ONE
  /// instance. Mutually exclusive with [active] (asserted in the
  /// constructor) — see `BannerAdWidget.controller`'s doc comment.
  final InlineAdController? controller;

  /// T240 — local fallback shown after [houseAdDelay] of sustained no-fill,
  /// offline, or gated state, same contract as `BannerAdWidget.houseAd`. MREC
  /// is a much larger blank area than banner (300x250 vs ~320x50), so the
  /// UX cost of leaving it empty is proportionally bigger.
  final HouseAdItem? houseAd;

  /// See `BannerAdWidget.houseAdDelay`'s doc comment — identical contract.
  final Duration houseAdDelay;

  @override
  State<MrecAdWidget> createState() => _MrecAdWidgetState();
}

class _MrecAdWidgetState extends State<MrecAdWidget>
    with RouteAware
    implements InlineAdControllerTarget {
  static const String _tag = 'MrecAdWidget';

  final ValueNotifier<bool> _initStarted = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);

  ModalRoute<void>? _subscribedRoute;

  bool _initScheduled = false;

  /// AdMob only: true while this route is the top route.
  final ValueNotifier<bool> _admobIsTop = ValueNotifier<bool>(false);

  /// Round-31 audit fix (MAJOR) — see `BannerAdWidget`'s matching field
  /// for the full reasoning (IndexedStack/PageView tab switches keep this
  /// widget mounted with no route change to key off).
  bool? _lastTickerMode;

  /// Round-39 audit fix (MAJOR) — see `BannerAdWidget`'s matching field for
  /// the full reasoning.
  bool? _lastEffectiveVisible;

  /// Round-39 audit re-review (MAJOR, independent Gemini pass) — see
  /// `BannerAdWidget._bannerInitCalled`'s doc comment for the full reasoning;
  /// this widget follows the identical pattern.
  bool _mrecInitCalled = false;

  /// T231 — recorder-only transition dedup, independent of
  /// [_lastEffectiveVisible] for the same reason as BannerAdWidget's matching
  /// field: manual `active`/controller overrides still need REAL on-screen
  /// evidence from [VisibilityDetector].
  bool? _lastFlightRecorderVisible;
  Offset _lastFlightRecorderOrigin = Offset.zero;
  Size _lastFlightRecorderSize = Size.zero;

  /// T241 audit follow-up — see BannerAdWidget's matching field doc comment:
  /// the recorder instance that actually holds the open `mrecVisible`
  /// interval, so [dispose] closes against the right chain even if a host
  /// swaps/disables the recorder before this widget unmounts.
  AdFlightRecorder? _lastFlightRecorderInstance;

  /// Mirrors BannerAdWidget's matching getter — shared by
  /// [_recordFlightRecorderVisibility] and the dispose-time close so both
  /// agree on whether house-ad content is on screen right now.
  bool get _isShowingHouseAdFallback =>
      widget.houseAd != null &&
      (!_allowed.value || AdManager().mrecHasError(this).value);

  void _recordFlightRecorderVisibility(VisibilityInfo info) {
    final recorder = AdManager().flightRecorder;
    if (recorder == null) return;
    // T240 preserves T237's invariant for the new MREC fallback: local house
    // content is not provider evidence. The same state that selects a fallback
    // render branch gates recorder writes, so evidence cannot drift from UI.
    if (_isShowingHouseAdFallback) {
      return;
    }
    final visible = info.visibleFraction > 0;
    if (_lastFlightRecorderVisible == visible) return;
    _lastFlightRecorderVisible = visible;
    final box = context.findRenderObject();
    final origin = (box is RenderBox && box.attached)
        ? box.localToGlobal(Offset.zero)
        : Offset.zero;
    final size = (box is RenderBox) ? box.size : Size.zero;
    if (visible) {
      _lastFlightRecorderOrigin = origin;
      _lastFlightRecorderSize = size;
      _lastFlightRecorderInstance = recorder;
    }
    unawaited(AdManager().recordFlightRecorderEvent(
      label: visible ? 'mrecVisible' : 'mrecHidden',
      type: AdSlotType.mrec,
      placement: widget.placement,
      viewabilityFraction: info.visibleFraction,
      screenX: origin.dx,
      screenY: origin.dy,
      widthPx: size.width,
      heightPx: size.height,
    ));
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    // See `BannerAdWidget._onVisibilityChanged`'s doc comment for why this
    // must be checked explicitly here.
    if (!mounted) return;
    _recordFlightRecorderVisibility(info);
    if (widget.active != null || widget.controller != null) return;
    _applyVisibility(info.visibleFraction > 0);
  }

  // ─── InlineAdControllerTarget (T201) ────────────────────────────────────

  @override
  void controllerRefresh() {
    if (!mounted) return;
    // Audit finding (self-review) — see BannerAdWidget.controllerRefresh's
    // matching comment: refresh() must not silently resume a paused slot.
    if (_pausedByController) {
      SafeLogger.d(_tag, 'controllerRefresh ⏭️ paused');
      return;
    }
    final mgr = AdManager();
    if (!mgr.canLoadMrec(this)) {
      SafeLogger.d(_tag, 'controllerRefresh ⏭️ cooldown');
      return;
    }
    SafeLogger.d(_tag, 'controllerRefresh — reloading');
    mgr.disposeMrecInstance(this);
    _allowed.value = false;
    _initMrec(context);
  }

  @override
  void controllerSetPaused(bool paused) {
    if (!mounted) return;
    _applyVisibility(!paused);
    // T201 — see BannerAdWidget.controllerSetPaused's matching comment.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// T201 — see `BannerAdWidget._pausedByController`'s doc comment.
  bool get _pausedByController =>
      widget.controller?.status == InlineAdControllerStatus.paused;

  void _applyVisibility(bool visible) {
    final last = _lastEffectiveVisible;
    _lastEffectiveVisible = visible;
    if (last == visible) return;
    if (visible) {
      if (!_mrecInitCalled) {
        _initMrec(context);
      } else if (last != null) {
        didPopNext();
      }
    } else {
      if (_mrecInitCalled) didPushNext();
    }
  }

  @override
  void didUpdateWidget(MrecAdWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = widget.active;
    if (active != null) _applyVisibility(active);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.detach(this);
      widget.controller?.attach(this);
    }
  }

  @override
  void initState() {
    super.initState();
    SafeLogger.d(_tag, 'initState');
    widget.controller?.attach(this);
    AdManager().canRequestAdsListenable.addListener(_onCanRequestAdsChanged);
    // M1 — withdrawing personalisation does NOT close the canRequestAds gate,
    // so the listener above never fires for it and this widget would keep
    // showing (and refreshing) an ad loaded under the old consent.
    AdManager()
        .personalisationRevision
        .addListener(_onPersonalisationWithdrawn);
  }

  /// Audit fix — see [BannerAdWidget]'s twin of this method.
  /// M1 — drop the live instance so the next load carries the new consent,
  /// then re-run init. Mirrors the gate-closed path below, which is the only
  /// mechanism in this widget that reliably replaces a mounted ad.
  void _onPersonalisationWithdrawn() {
    if (!mounted) return;
    final mgr = AdManager();
    SafeLogger.w(
        _tag, '🔒 personalisation withdrawn — replacing mounted MREC instance');
    mgr.disposeMrecInstance(this);
    _allowed.value = false;
    if (!mgr.canRequestAds || !mgr.isInitialised || mgr.isVIPMember()) return;
    // Round-39 audit re-review (MAJOR) — see BannerAdWidget's matching
    // comment: this consent-driven reinit path is independent of the
    // active-param gate and must respect it too.
    if (widget.active == false || _pausedByController) return;
    if (_initScheduled) return;
    _initScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initScheduled = false;
      if (!mounted) return;
      _initMrec(context);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _onCanRequestAdsChanged() {
    final mgr = AdManager();
    if (mgr.canRequestAds) {
      if (!_allowed.value &&
          !_initScheduled &&
          mgr.isInitialised &&
          !mgr.isVIPMember() &&
          widget.active != false &&
          !_pausedByController) {
        _initScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _initScheduled = false;
          if (!mounted) return;
          _initMrec(context);
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
      SafeLogger.w(
          _tag, '🔒 consent gate closed — disposing mounted mrec instance');
      mgr.disposeMrecInstance(this);
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
    // Round-31 audit fix (MAJOR) — see `_lastTickerMode`'s doc comment and
    // `BannerAdWidget`'s matching hook, which this mirrors.
    // T170 — see BannerAdWidget's matching hook for why this stays on the
    // deprecated `of` (suppressed) instead of migrating to `valuesOf`.
    // ignore: deprecated_member_use
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
      // Round-39 audit re-review (MAJOR) — mounting directly with
      // active: false must never load in the first place; see
      // BannerAdWidget's matching comment for the full reasoning.
      if (widget.active == false || _pausedByController) {
        _lastEffectiveVisible = false;
      } else {
        _initMrec(context);
      }
    }
  }

  void _initMrec(BuildContext ctx) {
    _mrecInitCalled = true;
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
    if (!mgr.canLoadMrec(this)) {
      SafeLogger.d(_tag, '_initMrec ⏭️ cooldown');
      return;
    }
    mgr.recordMrecLoad(this);
    _allowed.value = true;

    if (mgr.isAdMobProvider) {
      final width = MediaQuery.of(ctx).size.width;
      mgr.loadAdmobMrecIfNeeded(this, width);
    } else {
      // T65 (phase 3) — each MrecAdWidget instance now triggers its own
      // keyed preload on mount, mirroring BannerAdWidget.
      SafeLogger.d(_tag, '_initMrec [AppLovin] preloading own instance');
      mgr.preloadMrec(this);
    }
  }

  // ─── RouteAware hooks ────────────────────────────────────────────────────

  @override
  void didPush() {
    final mgr = AdManager();
    if (!mgr.isAdMobProvider) {
      // Round-32 QC (reviewer B, BLOCKER) — `setMrecRoutePaused` already
      // releases the route's own hold by name, through the adapter's ownership
      // bookkeeping. The direct write that used to sit here ran one frame after
      // EVERY mount (`RouteObserver.subscribe` calls `didPush` unconditionally)
      // and set `autoRefreshEnabled = true` over whatever else was holding it —
      // most damagingly the `fullscreen` hold a launch App Open had just taken.
      // The adapter was rebuilt around ownership in rounds 30–31; the widget
      // kept writing the flag directly, and the widget wins because it writes
      // last.
      mgr.setMrecRoutePaused(this, false);
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
      mgr.setMrecRoutePaused(this, true);
    } else if (_admobIsTop.value) {
      _admobIsTop.value = false;
      // Round-29 audit (MAJOR) — same gap as BannerAdWidget: AdMob's
      // Flutter plugin has no runtime pause API for an already-loaded ad,
      // so the cached MREC kept refreshing while invisible. Dispose it;
      // `didPopNext` below requests a fresh one on return.
      mgr.disposeMrecInstance(this);
      _allowed.value = false;
    }
    super.didPushNext();
  }

  @override
  void didPopNext() {
    // T201 — see BannerAdWidget.didPopNext's matching comment: returning
    // to this route must not silently override a controller-driven pause.
    if (!_pausedByController) {
      final mgr = AdManager();
      if (!mgr.isAdMobProvider) {
        mgr.setMrecRoutePaused(this, false);
      } else if (!_admobIsTop.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _admobIsTop.value = true;
          _initMrec(context);
        });
      }
    }
    super.didPopNext();
  }

  @override
  void didPop() {
    if (_admobIsTop.value) _admobIsTop.value = false;
    super.didPop();
  }

  /// T241 — unmounting while visible leaves the flight recorder evidence
  /// interval open indefinitely, since `VisibilityDetector` does not
  /// synthesize a final `visibleFraction = 0` callback upon disposal. Force
  /// the final `mrecHidden` entry before the widget is torn down, using the
  /// last known on-screen bounds (the render tree is about to be destroyed).
  ///
  /// T241 audit follow-up (reviewer finding, MAJOR) — mirrors
  /// BannerAdWidget's matching fix: skip the close entirely while a house-ad
  /// fallback is on screen, or this would tag a `mrecHidden` entry with the
  /// real provider's tag for content that is actually house-ad at teardown.
  ///
  /// T241 audit follow-up (reviewer finding, HIGH) — closes against
  /// [_lastFlightRecorderInstance], not whatever `AdManager().flightRecorder`
  /// is right now. See that field's doc comment.
  void _closeFlightRecorderVisibilityForUnmount() {
    if (_lastFlightRecorderVisible != true) return;
    _lastFlightRecorderVisible = false;
    final recorder = _lastFlightRecorderInstance;
    if (recorder == null || _isShowingHouseAdFallback) return;
    unawaited(AdManager().closeFlightRecorderInterval(
      recorder,
      label: 'mrecHidden',
      type: AdSlotType.mrec,
      placement: widget.placement,
      screenX: _lastFlightRecorderOrigin.dx,
      screenY: _lastFlightRecorderOrigin.dy,
      widthPx: _lastFlightRecorderSize.width,
      heightPx: _lastFlightRecorderSize.height,
    ));
  }

  @override
  void dispose() {
    _closeFlightRecorderVisibilityForUnmount();
    widget.controller?.detach(this);
    AdManager().canRequestAdsListenable.removeListener(_onCanRequestAdsChanged);
    AdManager()
        .personalisationRevision
        .removeListener(_onPersonalisationWithdrawn);
    if (_subscribedRoute != null) adRouteObserver.unsubscribe(this);
    AdManager().disposeMrecInstance(this);
    _admobIsTop.dispose();
    _initStarted.dispose();
    _allowed.dispose();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Round-39 audit fix (MAJOR) — see this widget's class doc comment and
    // `_onVisibilityChanged`. Keyed on the State object itself: stable
    // across rebuilds of this same instance, unique across every other one.
    return VisibilityDetector(
      key: ObjectKey(this),
      onVisibilityChanged: _onVisibilityChanged,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, _) {
        // Round-39 audit re-review (MAJOR) — see BannerAdWidget's matching
        // comment: this destroy→reinit retry path is independent of the
        // active-param gate and must respect it too.
        if (!_allowed.value &&
            !_initScheduled &&
            AdManager().isInitialised &&
            widget.active != false &&
            !_pausedByController) {
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
                if (!allowed) return _buildHouseAdOrEmpty();
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

  /// T240 — reuses `BannerAdWidget`'s [HouseAdSlot] verbatim (own timer/tap/
  /// teardown); the three blank-render sites this replaces are identical to
  /// BannerAdWidget's own (`!allowed`, AdMob `hasError`, AppLovin `hasError`).
  Widget _buildHouseAdOrEmpty() {
    final houseAd = widget.houseAd;
    if (houseAd == null) return const SizedBox.shrink();
    return HouseAdSlot(
      item: houseAd,
      delay: widget.houseAdDelay,
      logTag: 'MrecAdWidget',
    );
  }

  // ─── AdMob ───────────────────────────────────────────────────────────────

  Widget _buildAdmob() {
    return ValueListenableBuilder<bool>(
      valueListenable: _admobIsTop,
      builder: (context, isTop, _) {
        if (!isTop) {
          return ValueListenableBuilder<Size?>(
            valueListenable: AdManager().mrecAdSize(this),
            builder: (context, size, _) =>
                SizedBox(height: (size?.height ?? 250) + 16),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AdManager().mrecHasError(this),
          builder: (context, hasError, _) {
            if (hasError) return _buildHouseAdOrEmpty();
            return ValueListenableBuilder<bool>(
              valueListenable: AdManager().mrecVisible(this),
              builder: (context, visible, _) {
                if (!visible) {
                  return ValueListenableBuilder<Size?>(
                    valueListenable: AdManager().mrecAdSize(this),
                    builder: (context, size, _) =>
                        SizedBox(height: (size?.height ?? 250) + 16),
                  );
                }
                return _MrecContainer(
                  isLoaded: AdManager().mrecIsLoaded(this),
                  adSize: AdManager().mrecAdSize(this),
                  child: () {
                    final view = AdManager().admobMrecView(this);
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
      valueListenable: AdManager().mrecHasError(this),
      builder: (context, hasError, _) {
        if (hasError) return _buildHouseAdOrEmpty();
        return ValueListenableBuilder<Object?>(
          valueListenable: AdManager().mrecAdViewId(this),
          builder: (context, adViewId, _) {
            if (adViewId == null) return const _ShimmerOnlyMrecContainer();
            return _MrecContainer(
              isLoaded: AdManager().mrecIsLoaded(this),
              adSize: AdManager().mrecAdSize(this),
              child: () => _AppLovinMaxMrecView(
                key: ValueKey(adViewId),
                adViewId: adViewId as AdViewId,
                ownerKey: this,
                mrecId: AdManager().appLovinMrecId,
                autoRefresh: AdManager().mrecAutoRefreshEnabled(this),
                placement: widget.placement,
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
    super.key,
    required this.adViewId,
    required this.ownerKey,
    required this.mrecId,
    required this.autoRefresh,
    required this.placement,
  });

  final AdViewId adViewId;

  /// The owning `_MrecAdWidgetState` (`this` from its build method) —
  /// round-33 (R33-03), same reasoning as `_AppLovinMaxAdView.ownerKey` in
  /// banner_ad_widget.dart.
  final Object ownerKey;
  final String mrecId;
  final ValueListenable<bool> autoRefresh;
  final AdPlacement placement;

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
              // Round-46 audit fix (R46-03) — see banner_ad_widget.dart's
              // identical guard: drop a late callback for an adViewId this
              // widget has since moved on from.
              if (isStaleAppLovinCallback(
                  AdManager().mrecAdViewId(ownerKey).value, adViewId)) {
                return;
              }
              SafeLogger.d('MrecAdWidget', 'MaxAdView 🎯 click');
              AdSafetyConfig.recordAdClick();
              AdManager().adapter?.eventSink?.call(AdClickEvent(
                    providerTag: '[AppLovin]',
                    type: AdSlotType.mrec,
                    placement: placement,
                  ));
            },
            // Round-32 audit fix (MAJOR) — see banner_ad_widget.dart's
            // identical fix for the full explanation; same bug, same fix,
            // for MREC's own onAdLoadedCallback/_handleWidgetAdLoaded path.
            onAdRevenuePaidCallback: (ad) {
              // Round-33 (R33-03) — see banner_ad_widget.dart's identical
              // guard: drop a late callback for an adViewId this widget has
              // since moved on from.
              if (isStaleAppLovinCallback(
                  AdManager().mrecAdViewId(ownerKey).value, adViewId)) {
                return;
              }
              SafeLogger.d('MrecAdWidget', 'MaxAdView 💰 impression');
              AdSafetyConfig.recordBannerImpression();
              final sink = AdManager().adapter?.eventSink;
              sink?.call(AdImpressionEvent(
                providerTag: '[AppLovin]',
                type: AdSlotType.mrec,
                placement: placement,
              ));
              final revenue = appLovinRevenueEvent(ad,
                  type: AdSlotType.mrec, placement: placement);
              if (revenue != null) sink?.call(revenue);
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
