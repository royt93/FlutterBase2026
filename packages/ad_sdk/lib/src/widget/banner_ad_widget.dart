import 'dart:async';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../adapters/applovin_ad_revenue.dart';
import '../core/ad_manager.dart';
import '../core/ad_route_observer.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'inline_ad_controller.dart';
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
/// - auto-pauses when a [VisibilityDetector] reports it's scrolled off-screen
///   or obscured by another layer (round-39 audit fix) — but see [active]'s
///   doc comment for a real gap this does NOT cover
/// - delegates everything provider-specific to the active [AdProviderAdapter]
///
/// **`IndexedStack` still needs [active] wired manually.** A bottom-nav tab
/// built on a bare `IndexedStack` gives none of the signals above anything to
/// react to — worse, [VisibilityDetector] specifically *cannot* detect it
/// either: `RenderIndexedStack.paintStack` never calls `paint()` on a
/// non-current child at all, and `VisibilityDetector`'s own mechanism only
/// ever re-evaluates visibility from inside its `paint()` call. No paint call
/// ever happens for the hidden tab, so no "now invisible" signal ever fires —
/// this is a real limitation of the render pipeline, not something client
/// code can route around. Wrap each tab in `Visibility(maintainState: true)`
/// instead (works via `TickerMode`, see above) — or, if you must keep a bare
/// `IndexedStack`, pass `active: selectedIndex == myIndex` explicitly.
///
/// [active]: manual override — required for `IndexedStack` (see above), and
/// otherwise available for any other layout none of the automatic signals
/// can see through. Pass `false` while hidden and `true` (or omit — the
/// default, `null`, defers entirely to the automatic signals) once visible
/// again.
///
/// **AdMob sizing tracks its own container** — see [_resolveAdmobWidth] —
/// but only re-requests when the surrounding layout changes AND this
/// widget's Element actually reconciles. A `const BannerAdWidget()` inside a
/// container a host resizes is the one case that can miss this: Flutter
/// treats it as the identical instance across rebuilds and skips
/// reconciling it entirely, so it never learns the container resized.
/// Drop `const` if the surrounding container's size can change after
/// mount.
class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({
    super.key,
    this.collapseAnimationDuration = const Duration(milliseconds: 250),
    this.placement = AdPlacement.unspecified,
    this.active,
    this.controller,
  }) : assert(
          active == null || controller == null,
          'Pass either active or controller, not both — controller owns '
          'pause/resume once attached.',
        );

  /// T91 — how long the banner takes to animate its height when it
  /// collapses (no-fill, cooldown, VIP) or expands (a real ad becomes
  /// ready), instead of an abrupt `SizedBox.shrink()` layout jump. Pass
  /// `Duration.zero` to disable and get the old instant-jump behavior.
  final Duration collapseAnimationDuration;

  /// T107 — tags this instance for analytics/per-placement caps, same as
  /// the `placement` param on `showInterstitialAd`/`showRewardedAd`. Every
  /// `AdLoadEvent`/`AdShowEvent` this banner emits carries it.
  final AdPlacement placement;

  /// Manual visibility override — see the class doc comment. `null` (the
  /// default) defers entirely to the automatic [VisibilityDetector] signal.
  final bool? active;

  /// T201 — imperative refresh/pause/resume/status handle for this ONE
  /// instance. Mutually exclusive with [active] (asserted in the
  /// constructor): once a controller is attached it owns pause/resume,
  /// same as [active] would, but callable without a rebuild.
  final InlineAdController? controller;

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget>
    with RouteAware
    implements InlineAdControllerTarget {
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

  /// T157 — collapses a burst of [_maybeCorrectAdmobWidth] triggers (e.g.
  /// every tick of an animating container) into a single reload once the
  /// width actually settles. See [_maybeCorrectAdmobWidth]'s doc comment.
  Timer? _widthCorrectionDebounce;
  static const _widthCorrectionDebounceDuration = Duration(milliseconds: 300);

  /// T157 — this widget's own rendered width, read from [context] (via
  /// `context.size`, only ever valid AFTER layout completes — see
  /// [_refreshLayoutWidth]) rather than `MediaQuery.of(...).size.width` (the
  /// previous, only, width source): that is the FULL SCREEN, correct only
  /// when the banner happens to span it, and silently wrong (requests a
  /// too-wide adaptive banner, which then overflows) whenever a host places
  /// it inside anything narrower (a popup, a sidebar, a split-screen pane).
  /// `null` means "not measured yet" (nothing has completed layout with
  /// this widget in the tree so far) — every reader of this field falls
  /// back to `MediaQuery` in that case, preserving the old full-screen
  /// behavior exactly.
  ///
  /// Deliberately NOT a [LayoutBuilder]: an earlier version used one, and
  /// it silently broke [VisibilityDetector]'s own scroll-visibility
  /// callback entirely (0 calls — confirmed via
  /// test/banner_ad_widget_test.dart's scroll-away coverage). Reading
  /// `context.size` off this State's own existing Element inserts no new
  /// RenderObject into the tree at all, unlike LayoutBuilder.
  double? _layoutWidth;

  void _refreshLayoutWidth() {
    // T157 — reads the INCOMING constraint this widget's own RenderObject
    // (VisibilityDetector's) was laid out within, not its rendered SIZE
    // (`context.size`/`RenderBox.size`): the content collapses to
    // `SizedBox.shrink()` (0-width) whenever nothing has loaded yet
    // (`_allowed == false`, true for the entire first load this exists to
    // fix), so `context.size` would always read 0 at exactly the moment
    // this needs a real answer. `RenderBox.constraints` is available on any
    // already-laid-out RenderBox — no LayoutBuilder (a SEPARATE RenderObject)
    // needed to obtain it.
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      final maxWidth = ro.constraints.maxWidth;
      _layoutWidth = maxWidth.isFinite ? maxWidth : null;
    }
  }

  /// Resolves the width an AdMob adaptive banner should actually request:
  /// this widget's own constrained space when known, the screen otherwise.
  double _resolveAdmobWidth(BuildContext ctx) =>
      _layoutWidth ?? MediaQuery.of(ctx).size.width;

  /// Round-29 audit (MAJOR), reworked for T157 — reloads the AdMob adaptive
  /// banner when its real available width changes after already having
  /// loaded (rotation, split-screen, foldable unfold, or a host resizing
  /// the container it placed this widget in). AppLovin is exempt: its
  /// `MaxAdView` handles resizing natively (`isAdaptiveBannerEnabled:
  /// true`), and re-preloading it here would just tear down a perfectly
  /// good native view for nothing.
  ///
  /// Called from a postFrameCallback triggered by [_AdmobWidthObserver],
  /// which fires on every LAYOUT pass this widget goes through, for any
  /// cause — a dependency change like rotation, a host passing a new
  /// incoming constraint on rebuild, or even a relayout with no rebuild at
  /// all (an `AnimatedContainer` ancestor animating its own width ticks
  /// this on every frame of the animation). By the time it runs,
  /// [_refreshLayoutWidth] has already captured this frame's real,
  /// post-layout size, so the comparison below is never stale.
  ///
  /// Debounced (see [_widthCorrectionDebounce]): a continuously-animating
  /// container would otherwise trigger a real dispose+reload of the ad on
  /// EVERY intermediate tick, not just the final settled width — wasteful
  /// (a real ad network request per frame) for something that, in
  /// practice, only needs to happen once the resize actually settles.
  void _maybeCorrectAdmobWidth() {
    final mgr = AdManager();
    if (!_allowed.value || !mgr.isAdMobProvider) return;
    // codex re-review (P2) — resolved (fallback-aware), not raw
    // _layoutWidth: a loaded banner whose container BECOMES unbounded
    // (finite width -> null) must still be caught and reloaded at
    // MediaQuery's width, the same fallback _initBanner itself would use —
    // comparing the raw (now-null) _layoutWidth against _admobWidthPx
    // would short-circuit on `width == null` and leave it stale forever.
    if (_admobWidthPx == null || _resolveAdmobWidth(context) == _admobWidthPx) {
      return;
    }
    _widthCorrectionDebounce?.cancel();
    _widthCorrectionDebounce = Timer(_widthCorrectionDebounceDuration, () {
      if (!mounted) return;
      final mgr = AdManager();
      if (!_allowed.value || !mgr.isAdMobProvider) return;
      final width = _resolveAdmobWidth(context);
      if (_admobWidthPx == null || width == _admobWidthPx) return;
      SafeLogger.d(_tag,
          'width changed ($_admobWidthPx → $width) — reloading AdMob adaptive banner');
      mgr.disposeBannerInstance(this);
      _allowed.value = false;
      _initBanner(context);
    });
  }

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

  /// Round-39 audit fix (MAJOR) — mirrors [_lastTickerMode] but for the
  /// automatic [VisibilityDetector] signal (or [BannerAdWidget.active] when
  /// the host takes manual control), so a bare `IndexedStack` tab — which
  /// gives neither of the other two signals anything to react to — still
  /// gets paused/resumed via the same [didPushNext]/[didPopNext] path.
  bool? _lastEffectiveVisible;

  /// Round-39 audit re-review (MAJOR, independent Gemini pass) — whether
  /// [_initBanner] has ever actually been called. Needed to tell "never
  /// loaded at all" (mounted with `active: false` — the primary IndexedStack
  /// use case) apart from "loaded once, then paused" when [_applyVisibility]
  /// later sees `visible: true`: the former must call [_initBanner] itself
  /// (nothing to "resume" — [didPopNext] alone no-ops for AdMob when
  /// `_admobIsTop` is already true, which `didPush()` sets independently of
  /// `active` on every mount regardless), the latter must go through
  /// [didPopNext] as before.
  bool _bannerInitCalled = false;

  void _onVisibilityChanged(VisibilityInfo info) {
    // VisibilityDetector's composition callback can fire on a post-frame
    // schedule that outlives this State's own dispose() (unlike RouteAware,
    // which Flutter guarantees stops before that point) — mounted must be
    // checked here explicitly, or this reaches into an already-disposed
    // `_allowed` ValueNotifier via didPushNext/didPopNext.
    if (!mounted) return;
    // T201 — a controller owns pause/resume exactly like active would;
    // see this class's constructor assert (the two are mutually exclusive).
    if (widget.active != null || widget.controller != null) return;
    final visible = info.visibleFraction > 0;
    final mgr = AdManager();
    // T173 real-device root cause — an AdMob no-fill sets hasError=true, which
    // deliberately collapses this widget's own AnimatedSize to zero. That
    // self-collapse then produces a VisibilityDetector fraction of zero, but it
    // does NOT mean the still-mounted host scrolled or navigated away. Routing
    // that callback through didPushNext() removed the key from the adapter's
    // registry, so the debug overlay lost the failed slot and `needsRecovery`
    // was discarded before the resume scanner could retry it.
    //
    // Keep only this internally-collapsed AdMob error registered. There is no
    // live native BannerAd after onAdFailedToLoad, so retaining the bookkeeping
    // cannot refresh invisible inventory. Real route/TickerMode/manual pauses
    // bypass this callback and remain immediate; a genuinely off-screen widget
    // is detected again as soon as recovery clears the error and it expands.
    if (!visible &&
        _allowed.value &&
        mgr.isAdMobProvider &&
        mgr.bannerHasError(this).value) {
      return;
    }
    _applyVisibility(visible);
  }

  // ─── InlineAdControllerTarget (T201) ────────────────────────────────────

  @override
  void controllerRefresh() {
    if (!mounted) return;
    // Audit finding (self-review) — refresh() must not silently resume a
    // slot the controller has paused; every other reinit path already
    // gates on this, this one was missed.
    if (_pausedByController) {
      SafeLogger.d(_tag, 'controllerRefresh ⏭️ paused');
      return;
    }
    final mgr = AdManager();
    if (!mgr.canLoadBanner(this)) {
      SafeLogger.d(_tag, 'controllerRefresh ⏭️ cooldown');
      return;
    }
    SafeLogger.d(_tag, 'controllerRefresh — reloading');
    mgr.disposeBannerInstance(this);
    _allowed.value = false;
    _refreshLayoutWidth();
    _initBanner(context);
  }

  @override
  void controllerSetPaused(bool paused) {
    if (!mounted) return;
    _applyVisibility(!paused);
    // A host calls this from arbitrary code, not necessarily mid-build or
    // mid-route-transition — unlike the automatic paths that already
    // reuse _applyVisibility (VisibilityDetector's own paint cycle, a real
    // Navigator transition), nothing here otherwise guarantees a frame is
    // coming to actually run the addPostFrameCallback the AdMob branches
    // above may have just queued.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// T201 — every `widget.active == false`/`!= false` gate below must also
  /// treat a controller-paused instance the same way an explicit
  /// `active: false` would; the two are mutually exclusive (see the
  /// constructor assert), so at most one of them is ever actually driving
  /// this at a time.
  bool get _pausedByController =>
      widget.controller?.status == InlineAdControllerStatus.paused;

  void _applyVisibility(bool visible) {
    final last = _lastEffectiveVisible;
    _lastEffectiveVisible = visible;
    if (last == visible) return;
    if (visible) {
      if (!_bannerInitCalled) {
        // Never loaded at all — e.g. mounted with active: false and this is
        // the first time it's become active. Nothing to "resume": start a
        // real load. didPopNext() alone would wrongly no-op here for AdMob
        // (didPush() already set `_admobIsTop` true independently of
        // `active` back at mount — see `_bannerInitCalled`'s doc comment).
        //
        // T157 (codex re-review) — deferred one frame, same reason as the
        // first-mount branch in didChangeDependencies: this runs
        // synchronously mid-update (didUpdateWidget, itself called from
        // this branch's caller), before this frame's own layout has run,
        // so an immediate call would still see whatever _layoutWidth this
        // widget had (possibly null, e.g. an IndexedStack tab activated on
        // its very first frame) and fall back to MediaQuery's full-screen
        // value — this widget was already laid out at least once while
        // collapsed (SizedBox.shrink() while inactive, but still within
        // whatever real container the host placed it in), so a fresh
        // read one frame later already has the right answer, no different
        // from a completely fresh first load.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _refreshLayoutWidth();
          _initBanner(context);
        });
      } else if (last != null) {
        // A real resume — the very first callback ever (last == null) with
        // _bannerInitCalled already true (normal init already ran) must not
        // fire one before any pause has actually happened.
        didPopNext();
      }
    } else {
      // Unlike the visible branch above, this must fire even as the FIRST
      // callback (last == null): a bare `IndexedStack` tab that starts
      // hidden (any index other than the initially-selected one) needs its
      // very first, still-mounting frame suppressed just as much as a later
      // tab switch — that first frame is exactly the request this fix
      // exists to stop. Only meaningful once something has actually loaded.
      if (_bannerInitCalled) didPushNext();
    }
  }

  @override
  void didUpdateWidget(BannerAdWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = widget.active;
    if (active != null) _applyVisibility(active);
    // T201 — a host swapping in a different controller instance mid-life
    // (rare, but not a usage error) must move the attachment, not leave
    // the old controller pointing at a widget it can no longer command.
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
    // Round-39 audit re-review (MAJOR) — same active-param gate as the
    // build-time reinit path above; this consent-driven one is independent
    // of it and knew nothing about it either.
    if (widget.active == false || _pausedByController) return;
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
          !mgr.isVIPMember() &&
          widget.active != false &&
          !_pausedByController) {
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
      SafeLogger.w(
          _tag, '🔒 consent gate closed — disposing mounted banner instance');
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
    // T170 — TickerMode.of was deprecated after Flutter v3.35.0-0.0.pre in
    // favor of valuesOf, but valuesOf doesn't exist before that version and
    // this package declares `flutter: '>=3.27.0'` in pubspec.yaml — switching
    // would compile-fail for any consumer still on an older Flutter (codex
    // review caught this). Suppressing is the same workaround Flutter's own
    // deprecation doc comment on `of` recommends; revisit once the package's
    // floor moves past 3.35.
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
      // active: false (e.g. an IndexedStack tab that isn't the initially-
      // selected one) must never load in the first place; see
      // _bannerInitCalled's doc comment for how the eventual active:true
      // flip recovers from this without going through _initBanner twice.
      if (widget.active == false || _pausedByController) {
        _lastEffectiveVisible = false;
      } else {
        // T157 — deferred one frame: this FIRST-ever call happens before
        // this widget has ever completed layout (didChangeDependencies
        // always precedes the first build), so an immediate call here
        // would have no measured width yet and fall back to MediaQuery's
        // full-screen value — wasting a real AdMob request at the wrong
        // size for any constrained banner, exactly the bug this task
        // fixes. By the time a postFrameCallback fires, this same frame's
        // layout has already completed, so context.size is valid.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _refreshLayoutWidth();
          _initBanner(context);
        });
      }
      return;
    }
    // Round-29 audit (MAJOR) — reload the AdMob adaptive banner when the
    // available width actually changed (rotation, split-screen, foldable
    // unfold, or a host resizing the container it placed this widget in).
    //
    // T157 — the actual correction runs from [_AdmobWidthObserver] (see
    // its doc comment), a plain RenderProxyBox wired into build() below
    // whose performLayout fires on EVERY real layout pass this widget's
    // RenderObject goes through — independent of whether this Element
    // ever rebuilds at all (an ancestor like AnimatedContainer can
    // relayout its child every tick without rebuilding it), so this
    // method no longer needs its own copy of that check.
  }

  void _initBanner(BuildContext ctx) {
    _bannerInitCalled = true;
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
      // T157 — the widget's own constrained space, not the full screen;
      // see _resolveAdmobWidth's doc comment.
      final width = _resolveAdmobWidth(ctx);
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
    // T201 — returning to this route must not silently override a
    // controller-driven pause; controllerSetPaused(false) already re-runs
    // this exact reactivation itself (via _applyVisibility) once the host
    // actually resumes.
    if (!_pausedByController) {
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
    widget.controller?.detach(this);
    _widthCorrectionDebounce?.cancel();
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
    //
    final child = widget.collapseAnimationDuration == Duration.zero
        ? _buildBanner(context)
        : AnimatedSize(
            duration: widget.collapseAnimationDuration,
            alignment: Alignment.topCenter,
            child: _buildBanner(context),
          );
    // Round-39 audit fix (MAJOR) — see this widget's class doc comment and
    // _onVisibilityChanged. Keyed on the State object itself: stable across
    // rebuilds of this same instance, unique across every other banner.
    return VisibilityDetector(
      key: ObjectKey(this),
      onVisibilityChanged: _onVisibilityChanged,
      // T157 (codex re-review) — see _AdmobWidthObserver's doc comment:
      // catches a real resize even when nothing about this widget's own
      // Element ever rebuilds (e.g. an AnimatedContainer ancestor
      // relayouting its child every animation tick).
      child: _AdmobWidthObserver(
        onWidthChanged: () {
          if (!mounted) return;
          _refreshLayoutWidth();
          _maybeCorrectAdmobWidth();
        },
        child: child,
      ),
    );
  }

  // Outer subscription: initRevision — destroy → re-init (e.g. fresh init
  // completing AFTER this widget mounted) forces a retry of _initBanner
  // against the new adapter.
  Widget _buildBanner(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) {
        // Round-39 audit re-review (MAJOR) — this destroy→reinit retry path
        // is independent of the active-param gate above and knew nothing
        // about it: mounting with active: false still hit this on every
        // rebuild (initRevision listener fires unconditionally) and loaded
        // anyway. widget.active == false must suppress this exactly like it
        // suppresses the initial didChangeDependencies call.
        if (!_allowed.value &&
            !_initScheduled &&
            AdManager().isInitialised &&
            widget.active != false &&
            !_pausedByController) {
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
                key: ValueKey(adViewId),
                adViewId: adViewId as AdViewId,
                ownerKey: this,
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
    super.key,
    required this.adViewId,
    required this.ownerKey,
    required this.bannerId,
    required this.autoRefresh,
    required this.placement,
  });

  final AdViewId adViewId;

  /// The owning [_BannerAdWidgetState] (`this` from its build method) —
  /// round-33 (R33-03): lets the revenue callback re-check, at fire time,
  /// whether [adViewId] is still the one `AdManager` considers live for
  /// this widget before recording anything from it.
  final Object ownerKey;
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
              // Round-46 audit fix (R46-03) — same reasoning as the
              // onAdRevenuePaidCallback guard below (added round 33 for
              // revenue, missed for click until this round): a click
              // delivered for an adViewId this widget has since moved on
              // from — a reload, a dispose, or even a destroy()+re-init
              // that replaced the whole adapter (bannerAdViewId then
              // resolves against a fresh, unrelated registry and won't
              // match the captured id either) — must not be recorded.
              if (isStaleAppLovinCallback(
                  AdManager().bannerAdViewId(ownerKey).value, adViewId)) {
                return;
              }
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
              // Round-33 (R33-03) — drop a late callback for an adViewId
              // this widget has since moved on from (a reload handed out a
              // new one) instead of double-counting it as current revenue.
              if (isStaleAppLovinCallback(
                  AdManager().bannerAdViewId(ownerKey).value, adViewId)) {
                return;
              }
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

/// T157 (codex re-review, P1) — notifies on every LAYOUT pass where this
/// subtree's incoming width actually changes, even when no [Element] ever
/// rebuilds (e.g. an `AnimatedContainer` ancestor ticking its own width
/// animation, which relayouts its child every frame without necessarily
/// rebuilding it) — a rebuild-driven check alone is not guaranteed to run
/// for every real resize.
///
/// Deliberately NOT a [LayoutBuilder]: a [LayoutBuilder] defers building
/// its `builder` callback until layout time via a special reentrant
/// (`invokeLayoutCallback`) mechanism — placing one anywhere near
/// [VisibilityDetector] in this widget's tree (tried both as an ancestor
/// and as a descendant) silently broke its scroll-visibility callback
/// entirely (0 calls, confirmed via this file's own test coverage). This
/// is a plain [RenderProxyBox]: its child is built eagerly, exactly like
/// [Padding] or [Container] — structurally no different from any other
/// simple decorator widget that already coexists with [VisibilityDetector]
/// in real Flutter apps without issue. Reports no width value itself —
/// callers re-read the current one (via [BuildContext.findRenderObject])
/// once notified, since layout for this frame has already finished by the
/// time the deferred callback below actually runs.
class _AdmobWidthObserver extends SingleChildRenderObjectWidget {
  const _AdmobWidthObserver({required this.onWidthChanged, super.child});

  final VoidCallback onWidthChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAdmobWidthObserver(onWidthChanged);

  @override
  void updateRenderObject(
      BuildContext context, _RenderAdmobWidthObserver renderObject) {
    renderObject.onWidthChanged = onWidthChanged;
  }
}

class _RenderAdmobWidthObserver extends RenderProxyBox {
  _RenderAdmobWidthObserver(this.onWidthChanged);

  VoidCallback onWidthChanged;
  double? _lastWidth;
  bool _pendingReport = false;

  @override
  void performLayout() {
    super.performLayout();
    final maxWidth = constraints.maxWidth;
    final width = maxWidth.isFinite ? maxWidth : null;
    if (width == _lastWidth) return;
    _lastWidth = width;
    // Calling back into widget/element code (setState, etc.) synchronously
    // from inside performLayout — while Flutter is still laying THIS frame
    // out — is unsafe; deferring to a postFrameCallback is the same
    // pattern this file already uses everywhere else for exactly this
    // reason (see e.g. didPush, _onCanRequestAdsChanged).
    if (_pendingReport) return;
    _pendingReport = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pendingReport = false;
      onWidthChanged();
    });
  }
}
