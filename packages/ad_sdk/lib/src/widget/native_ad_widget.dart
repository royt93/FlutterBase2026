import 'dart:async';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

import '../adapters/applovin_ad_revenue.dart';
import '../adapters/applovin_adapter.dart';
import '../core/ad_manager.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'inline_ad_controller.dart';
import 'shimmer_view.dart';

/// Native ad widget — provider-agnostic.
///
/// Unlike [BannerAdWidget]/[MrecAdWidget], native ads have no adaptive size,
/// no auto-refresh ticker, and (on AppLovin) no `preloadWidgetAdView`/adViewId
/// bridge — `MaxNativeAdView` loads on mount as a self-contained widget. Both
/// branches render at a fixed height (Google's recommended 320 for
/// `TemplateType.medium`).
///
/// **No `RouteAware` here, deliberately (m25, decided 2026-08-23).** Banner and
/// MREC implement it because they own an auto-refresh ticker that would keep
/// requesting ads behind a covering route. Native has no such ticker, so there
/// is nothing to pause — the only thing route-awareness could add is destroying
/// the ad view while it is covered, and that trades the cache for a reload:
/// AdMob keeps the loaded ad in the adapter's `_nativeAdsByKey`, so tearing it
/// down on every push discards a ready ad and costs a fresh request (plus a
/// blank gap) each time the user comes back, while AppLovin cannot cache at all
/// — no preload bridge — so it would reload unconditionally. Neither buys an
/// impression. The case that genuinely needs teardown, a long feed of natives,
/// is already handled: `ListView` disposes off-screen items, which routes
/// through `disposeNativeInstance`. What remains held is one ad view per
/// mounted screen. See doc/audit/audit_claude.md § m25.
///
/// **T154 — [active] (default `true`) gates the ONE-TIME initial load —
/// there is no automatic signal, unlike Banner/MREC's `active`.** Those
/// widgets pair a manual override with an automatic `VisibilityDetector`
/// fallback because they need to PAUSE an already-loaded, auto-refreshing
/// ad once it scrolls off-screen. Native has neither an auto-refresh ticker
/// nor anything to pause once loaded, so a `VisibilityDetector` here would
/// buy nothing — worse, it would still fire too late to help: native's
/// initial load must happen in `initState` (there is no adaptive-size
/// platform round-trip to delay it behind, unlike Banner), which always
/// runs a full frame before any visibility callback ever could. Pass
/// `active: selectedIndex == myIndex` explicitly for any container that
/// mounts children it doesn't currently show — `IndexedStack` is the most
/// common case, and `VisibilityDetector` cannot help there either: its
/// hidden child is never painted at all (see [BannerAdWidget]'s doc
/// comment for why), so no signal would ever fire regardless.
///
/// Place anywhere in your screen tree:
/// ```dart
/// Column(children: [buildNative(), ...])   // inside an AdScreenState
/// // or directly:
/// const NativeAdWidget()
/// // in-feed / ListView (T73) — small template, no explicit height needed:
/// const NativeAdWidget(templateType: TemplateType.small)
/// // custom height MUST match templateType — AdMob's own template guide
/// // recommends a minimum of 90 for small / 320 for medium (audit round
/// // 42); pairing a short custom height with the medium template (this
/// // widget's default) clips or overflows provider-rendered content:
/// const NativeAdWidget(templateType: TemplateType.small, height: 120)
/// ```
///
/// ## T228 — custom native layout
///
/// **AdMob:** pass [factoryId] to opt into a host-registered platform-side
/// `NativeAdFactory` (Kotlin/Swift) instead of [templateType]'s built-in
/// Google template. This is NOT a pure-Dart custom layout — Google's own
/// `google_mobile_ads` plugin does not support building native ad UI out of
/// Flutter widgets at all (its `NativeAd` doc says so explicitly); the
/// actual view is drawn by native platform code the HOST app registers in
/// its own `MainActivity`/`AppDelegate`. See `example/android` and
/// `example/ios` for a working reference `NativeAdFactory`, and
/// `README.md`'s "Custom native ad layout (AdMob)" section for the
/// registration steps. Leaving [factoryId] null (the default) is a
/// zero-behavior-change no-op — existing hosts keep getting
/// [templateType]'s Google-drawn template exactly as before.
///
/// **AppLovin:** pass [customNativeAdBuilder] for a genuine pure-Dart
/// custom layout — `MaxNativeAdView`'s asset views
/// (`MaxNativeAdTitleView`/`MaxNativeAdBodyView`/etc.) are ordinary Flutter
/// widgets already; this just lets the host arrange them instead of using
/// this widget's built-in arrangement. The mandatory `MaxNativeAdOptionsView`
/// attribution badge is always overlaid by the SDK itself — the host
/// builder never places it and cannot omit it; host content is inset by the
/// same 24px from top/right so it cannot cover that square in normal layout.
/// If [height] leaves less than [kMinNativeAdAttributionSize] logical pixels
/// for the overlay, the SDK
/// fails safe and ignores the custom builder, falling back to this widget's
/// standard AppLovin layout instead (still fully compliant).
class NativeAdWidget extends StatefulWidget {
  const NativeAdWidget({
    super.key,
    this.templateType = TemplateType.medium,
    this.height,
    this.placement = AdPlacement.unspecified,
    this.active = true,
    this.controller,
    this.factoryId,
    this.customNativeAdBuilder,
  })  : assert(
          active || controller == null,
          'Pass either active: false or a controller, not both — attach a '
          'controller and call pause() instead of also passing active: '
          'false.',
        ),
        assert(
          factoryId == null || factoryId != '',
          'factoryId must not be blank — pass null to use the built-in '
          'AdMob template instead.',
        );

  /// T107 — tags this instance for analytics/per-placement caps, same as
  /// the `placement` param on `showInterstitialAd`/`showRewardedAd`.
  final AdPlacement placement;

  /// T154 — whether this instance is currently allowed to load/show. See
  /// the class doc comment for how this differs from
  /// `BannerAdWidget.active`/`MrecAdWidget.active` (no automatic fallback
  /// here — pass it explicitly wherever this widget could mount hidden).
  final bool active;

  /// T201 — imperative refresh/pause/resume/status handle for this ONE
  /// instance. Mutually exclusive with `active: false` (asserted in the
  /// constructor) — see `BannerAdWidget.controller`'s doc comment.
  /// Pausing a native instance disposes it (there is no auto-refresh
  /// ticker to merely suspend, unlike Banner/MREC); resuming re-loads it
  /// through the same gates a fresh mount would.
  final InlineAdController? controller;

  /// AdMob's built-in native template layout. Ignored by AppLovin (no
  /// equivalent concept — `MaxNativeAdView` is a custom-drawn layout).
  /// Also picks this widget's default [height] when that's not set
  /// explicitly: 320 for [TemplateType.medium], 90 for [TemplateType.small].
  final TemplateType templateType;

  /// Overrides the default height implied by [templateType] — applies to
  /// both providers' layout, since AppLovin has no template concept at all.
  final double? height;

  /// T228 — AdMob only. Opts into a host-registered platform-side
  /// `NativeAdFactory`/`FLTNativeAdFactory` instead of [templateType]'s
  /// built-in Google template. Ignored by AppLovin. See the class doc
  /// comment's "T228 — custom native layout" section.
  final String? factoryId;

  /// T228 — AppLovin only. Host-supplied layout replacing this widget's
  /// standard AppLovin arrangement; the SDK still always overlays the
  /// mandatory `MaxNativeAdOptionsView` attribution badge on top, and falls
  /// back to the standard layout if [height] leaves no room for it. Ignored
  /// by AdMob (see [factoryId] for AdMob's own, differently-shaped opt-in).
  final CustomNativeAdBuilder? customNativeAdBuilder;

  /// T239 — pure reload-decision key: whether the AdMob-relevant config
  /// (`factoryId`/`templateType`) actually changed between two widget
  /// configurations. Extracted so it's unit-testable without a
  /// `WidgetTester`. Exposed for tests; [_NativeAdWidgetState.didUpdateWidget]
  /// is the only production caller.
  @visibleForTesting
  static bool debugConfigChanged(
      NativeAdWidget oldWidget, NativeAdWidget widget) =>
      widget.factoryId != oldWidget.factoryId ||
      widget.templateType != oldWidget.templateType;

  @override
  State<NativeAdWidget> createState() => _NativeAdWidgetState();
}

/// T228 — host-supplied layout for [NativeAdWidget.customNativeAdBuilder]
/// (AppLovin only). Build with `MaxNativeAdView`'s asset-view widgets
/// (`MaxNativeAdTitleView`, `MaxNativeAdBodyView`, `MaxNativeAdIconView`,
/// `MaxNativeAdMediaView`, `MaxNativeAdCallToActionView`,
/// `MaxNativeAdStarRatingView`, `MaxNativeAdAdvertiserView`) in any
/// arrangement — do NOT include `MaxNativeAdOptionsView` yourself, the SDK
/// always overlays it.
typedef CustomNativeAdBuilder = Widget Function(BuildContext context);

/// T228 — minimum square size (logical px) the SDK reserves in a corner for
/// the mandatory `MaxNativeAdOptionsView` attribution badge. Below this, a
/// [CustomNativeAdBuilder] is rejected (fail-safe fallback to the standard
/// layout) rather than risk the badge being clipped or overlapping content.
const double kMinNativeAdAttributionSize = 24;

class _NativeAdWidgetState extends State<NativeAdWidget>
    implements InlineAdControllerTarget {
  static const String _tag = 'NativeAdWidget';

  double get _height =>
      widget.height ?? (widget.templateType == TemplateType.small ? 90 : 320);

  final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);
  bool _initScheduled = false;
  bool _didLogCustomLayoutFallback = false;

  /// Round-29 audit (MINOR) — unlike Banner/Mrec (which get a fresh shot
  /// whenever consent/personalisation/initRevision changes reset `_allowed`),
  /// nothing ever reset `_allowed` after a native load failure, so a failed
  /// instance stayed blank for the rest of the widget's lifetime — the only
  /// way out was leaving and re-entering the route. This retries once after
  /// a fixed backoff instead.
  Timer? _retryTimer;

  /// Round-31 audit fix (MAJOR) — the notifier [AdManager.nativeHasError]
  /// returns is per-bundle, and `disposeNativeInstance(this)` (called from
  /// [_onPersonalisationWithdrawn] and [_onCanRequestAdsChanged] below)
  /// drops the old bundle and lets the next `native(this)`/
  /// `nativeHasError(this)` access create a brand new one. [initState] only
  /// ever subscribed [_onNativeErrorChanged] to the ORIGINAL notifier, so
  /// after any dispose/revive cycle (a very common one: a consent gate
  /// closing then reopening) the retry-after-30s mechanism this listener
  /// implements silently stopped working — right back to the bug it was
  /// added to fix. Tracked so [dispose] can also unsubscribe from whichever
  /// notifier is actually current, not a stale reference.
  ValueListenable<bool>? _subscribedNativeErrorNotifier;

  void _subscribeNativeError() {
    final notifier = AdManager().nativeHasError(this);
    if (identical(notifier, _subscribedNativeErrorNotifier)) return;
    _subscribedNativeErrorNotifier?.removeListener(_onNativeErrorChanged);
    notifier.addListener(_onNativeErrorChanged);
    _subscribedNativeErrorNotifier = notifier;
  }

  @override
  void didUpdateWidget(NativeAdWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // T154 — host flipped active:false → true (e.g. IndexedStack tab
    // switch) after this widget mounted hidden and never loaded (or its
    // load previously failed and reset `_allowed`, same as every other
    // retry path in this class — see `_onCanRequestAdsChanged`).
    if (widget.active && !_allowed.value) _initNative();
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.detach(this);
      widget.controller?.attach(this);
    }
    // T239 — AdMob's factoryId/templateType select which platform-side
    // NativeAdFactory or built-in template the ad loads with. Changing
    // either at runtime on an already-loaded/in-flight instance previously
    // did nothing: `preloadNative()` early-returns once the adapter already
    // has a cached NativeAd for this key, so the widget kept showing the
    // OLD factory/template forever. Only relevant while `_allowed` is
    // already true — while blocked (VIP/consent/offline/cooldown) this must
    // NOT force a load; the existing gates above/in `_initNative()` already
    // pick up the latest `widget.factoryId`/`widget.templateType` once the
    // gate reopens. AppLovin has no equivalent concept for either field
    // (ignored — see class doc "T228 — custom native layout"); a
    // `customNativeAdBuilder` swap is pure Dart and just re-renders on the
    // next build, no adapter-level reload needed.
    if (_allowed.value &&
        AdManager().isAdMobProvider &&
        NativeAdWidget.debugConfigChanged(oldWidget, widget)) {
      SafeLogger.d(_tag,
          'didUpdateWidget factoryId/templateType changed — reloading native');
      AdManager().disposeNativeInstance(this);
      _allowed.value = false;
      _initNative();
    }
  }

  @override
  void initState() {
    super.initState();
    SafeLogger.d(_tag, 'initState');
    widget.controller?.attach(this);
    // T154 — active: false (e.g. an IndexedStack tab that isn't the
    // initially-selected one) must never load in the first place; the
    // didUpdateWidget hook above picks it up once it flips to true.
    if (widget.active) _initNative();
    AdManager().canRequestAdsListenable.addListener(_onCanRequestAdsChanged);
    // M1 — withdrawing personalisation does NOT close the canRequestAds gate,
    // so the listener above never fires for it and this widget would keep
    // showing (and refreshing) an ad loaded under the old consent.
    AdManager()
        .personalisationRevision
        .addListener(_onPersonalisationWithdrawn);
    _subscribeNativeError();
  }

  void _onNativeErrorChanged() {
    if (!mounted) return;
    if (!AdManager().nativeHasError(this).value) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      SafeLogger.d(_tag, 'retrying after load failure');
      // Round-38 audit fix (MAJOR) — AdMob's own load call resets its
      // `hasError` notifier on retry, but AppLovin's native view only ever
      // loads on mount, and mount is gated on `hasError == false` (see
      // _buildAppLovin). Without dropping the stale bundle first, AppLovin
      // native ads stayed blank forever after a single load failure — this
      // timer kept firing but had no effect. Mirrors
      // _onPersonalisationWithdrawn/_onCanRequestAdsChanged just below.
      AdManager().disposeNativeInstance(this);
      _allowed.value = false;
      // T154 (codex re-review) — a hidden tab must still get this reset
      // (an earlier version returned early instead and skipped it), or
      // `_allowed` stayed stuck true+errored forever: `didUpdateWidget`'s
      // own retry only fires on `!_allowed.value`, so reactivating this
      // widget later would never load anything again. Only the actual
      // reload is conditional on `active` — the retry chance itself is not.
      if (widget.active) _initNative();
    });
  }

  /// Audit fix — see [BannerAdWidget]'s twin of this method.
  /// M1 — drop the live instance so the next load carries the new consent,
  /// then re-run init. Mirrors the gate-closed path below, which is the only
  /// mechanism in this widget that reliably replaces a mounted ad.
  void _onPersonalisationWithdrawn() {
    if (!mounted) return;
    final mgr = AdManager();
    SafeLogger.w(_tag,
        '🔒 personalisation withdrawn — replacing mounted native instance');
    mgr.disposeNativeInstance(this);
    _allowed.value = false;
    if (!mgr.canRequestAds || !mgr.isInitialised || mgr.isVIPMember()) return;
    if (!widget.active) return;
    if (_initScheduled) return;
    _initScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initScheduled = false;
      if (!mounted) return;
      _initNative();
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
          widget.active) {
        _initScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _initScheduled = false;
          if (!mounted) return;
          _initNative();
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
          _tag, '🔒 consent gate closed — disposing mounted native instance');
      mgr.disposeNativeInstance(this);
      _allowed.value = false;
    }
  }

  void _initNative() {
    // T154 (codex re-review, P1) — every call site above only checks
    // `widget.active` at SCHEDULE time; the three that go through
    // `addPostFrameCallback` (personalisation-withdrawn, consent-reopen,
    // build's own retry) can fire a frame or more later, after a parent
    // rebuild has since flipped this widget back to hidden. The single
    // authoritative check belongs here, exactly like every other gate
    // below (mgr.isInitialised/isVIPMember/canRequestAds/...) — those
    // callers already rely on `_initNative()` alone being the source of
    // truth, not on their own schedule-time pre-filter.
    if (!widget.active || _pausedByController) {
      SafeLogger.d(_tag, '_initNative ⏭️ inactive');
      return;
    }
    // T154 (codex re-review, P1) — a post-frame callback queued while
    // `_allowed` was still false (consent-reopen/personalisation-withdrawn/
    // build's retry) can be overtaken by `didUpdateWidget` firing a
    // SYNCHRONOUS `_initNative()` earlier in that same frame (any parent
    // rebuild re-triggers it, not just an active flip). Without this, both
    // calls pass every gate below and `mgr.recordNativeLoad`/the real
    // provider load both fire twice for one transition. Every legitimate
    // retry path (`_onNativeErrorChanged`, `_onPersonalisationWithdrawn`,
    // the consent-close branch of `_onCanRequestAdsChanged`) already resets
    // `_allowed` to false right before calling this, so this only ever
    // blocks the genuine duplicate, never a real retry.
    if (_allowed.value) {
      SafeLogger.d(_tag, '_initNative ⏭️ already allowed/in-flight');
      return;
    }
    final mgr = AdManager();
    if (!mgr.isInitialised) {
      SafeLogger.d(_tag, '_initNative ⏭️ AdManager not initialised yet');
      return;
    }
    if (mgr.isVIPMember()) {
      SafeLogger.d(_tag, '_initNative ⏭️ VIP');
      return;
    }
    if (!mgr.canRequestAds) {
      SafeLogger.d(_tag, '_initNative ⏭️ consent not granted (UMP)');
      return;
    }
    if (!mgr.isConnected) {
      SafeLogger.d(_tag, '_initNative ⏭️ offline');
      return;
    }
    if (!mgr.canLoadNative(this)) {
      SafeLogger.d(_tag, '_initNative ⏭️ cooldown');
      return;
    }
    mgr.recordNativeLoad(this);
    _allowed.value = true;
    // Round-31 audit fix — `disposeNativeInstance` (called by the two
    // listeners above before re-triggering this method) may have replaced
    // the bundle `nativeHasError(this)` reads from; re-subscribe to
    // whichever one is current. See `_subscribedNativeErrorNotifier`'s doc.
    _subscribeNativeError();

    if (mgr.isAdMobProvider) {
      mgr.loadAdmobNativeIfNeeded(this,
          templateType: widget.templateType, factoryId: widget.factoryId);
    } else {
      SafeLogger.d(
          _tag, '_initNative [AppLovin] MaxNativeAdView loads on mount');
    }
  }

  // ─── InlineAdControllerTarget (T201) ────────────────────────────────────

  @override
  void controllerRefresh() {
    if (!mounted) return;
    final mgr = AdManager();
    if (!mgr.canLoadNative(this)) {
      SafeLogger.d(_tag, 'controllerRefresh ⏭️ cooldown');
      return;
    }
    SafeLogger.d(_tag, 'controllerRefresh — reloading');
    mgr.disposeNativeInstance(this);
    _allowed.value = false;
    _initNative();
  }

  @override
  void controllerSetPaused(bool paused) {
    // T201 — native has no auto-refresh ticker to merely suspend
    // (see this class's doc comment), so "paused" disposes the live
    // instance outright and "resumed" reloads it through the same gates
    // a fresh mount would — `_initNative`'s own top check on
    // `_pausedByController` is what actually keeps it from reloading
    // itself right back while still paused.
    if (!mounted) return;
    if (paused) {
      if (!_allowed.value) return;
      SafeLogger.d(_tag, 'controller paused — disposing native instance');
      AdManager().disposeNativeInstance(this);
      _allowed.value = false;
      return;
    }
    if (!_allowed.value) _initNative();
  }

  /// T201 — see `BannerAdWidget._pausedByController`'s doc comment.
  bool get _pausedByController =>
      widget.controller?.status == InlineAdControllerStatus.paused;

  @override
  void dispose() {
    widget.controller?.detach(this);
    AdManager().canRequestAdsListenable.removeListener(_onCanRequestAdsChanged);
    AdManager()
        .personalisationRevision
        .removeListener(_onPersonalisationWithdrawn);
    // Round-31 audit fix — remove from whichever notifier was actually
    // subscribed (see `_subscribedNativeErrorNotifier`'s doc), not a fresh
    // `nativeHasError(this)` read here, which could be a bundle created
    // AFTER the last subscribe and therefore never actually listened to.
    _subscribedNativeErrorNotifier?.removeListener(_onNativeErrorChanged);
    _retryTimer?.cancel();
    AdManager().disposeNativeInstance(this);
    _allowed.dispose();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, _) {
        if (!_allowed.value &&
            !_initScheduled &&
            AdManager().isInitialised &&
            widget.active) {
          _initScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _initScheduled = false;
            if (!mounted) return;
            _initNative();
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
                // Round-44 audit fix — a live native ad used to stay
                // mounted and visible under an App Open ad; `nativeVisible`
                // now drives this the same way `bannerVisible` already
                // gates BannerAdWidget's render.
                return ValueListenableBuilder<bool>(
                  valueListenable: mgr.nativeVisible(this),
                  builder: (context, visible, _) {
                    if (!visible) {
                      return SizedBox(height: _height, width: double.infinity);
                    }
                    return mgr.isAdMobProvider
                        ? _buildAdmob()
                        : _buildAppLovin();
                  },
                );
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
  // AdMob's native template auto-draws the "Ad"/AdChoices attribution — no
  // package-drawn badge on this branch (unlike AppLovin below).

  Widget _buildAdmob() {
    return ValueListenableBuilder<bool>(
      valueListenable: AdManager().nativeHasError(this),
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: AdManager().nativeIsLoaded(this),
          builder: (context, loaded, _) {
            if (!loaded) {
              return ShimmerView(
                  cornerRadius: 0, width: double.infinity, height: _height);
            }
            final view = AdManager().admobNativeView(this);
            if (view == null) {
              return SizedBox(height: _height, width: double.infinity);
            }
            return SizedBox(
                height: _height, width: double.infinity, child: view);
          },
        );
      },
    );
  }

  // ─── AppLovin ────────────────────────────────────────────────────────────
  // MaxNativeAdView is genuine custom Dart layout — the package must draw
  // its own compliance "Ad" badge (mirrors _MrecContainer's badge).

  Widget _buildAppLovin() {
    return ValueListenableBuilder<bool>(
      valueListenable: AdManager().nativeHasError(this),
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();
        return LayoutBuilder(builder: (context, constraints) {
          final customBuilder = widget.customNativeAdBuilder;
          final hasAttributionRoom = _height >= kMinNativeAdAttributionSize &&
              (!constraints.hasBoundedWidth ||
                  constraints.maxWidth >= kMinNativeAdAttributionSize);
          final useCustom = customBuilder != null && hasAttributionRoom;
          if (customBuilder != null && !hasAttributionRoom) {
            if (!_didLogCustomLayoutFallback) {
              _didLogCustomLayoutFallback = true;
              SafeLogger.w(_tag,
                  'custom AppLovin native layout fallback — less than '
                  '${kMinNativeAdAttributionSize.toInt()}x'
                  '${kMinNativeAdAttributionSize.toInt()} logical pixels '
                  'available for mandatory AdOptions attribution');
            }
          } else {
            _didLogCustomLayoutFallback = false;
          }
          // A custom layout that was rejected for compliance still needs a
          // usable standard surface. Clamp only that opt-in failure path to
          // the standard AppLovin layout's existing default height;
          // default/no-builder behavior remains byte-for-byte unchanged.
          final effectiveHeight = customBuilder != null && !hasAttributionRoom
              ? _height.clamp(320, double.infinity).toDouble()
              : _height;
          return _NativeContainer(
            isLoaded: AdManager().nativeIsLoaded(this),
            height: effectiveHeight,
            child: () {
              if (AdManager().debugShouldSkipRealAppLovinNativeView) {
                // Debug-only, explicit opt-in (see
                // debugForceSkipRealAppLovinNativeView doc) — everything
                // above (error-collapse, shimmer) is real widget behavior
                // the caller must still exercise.
                return const SizedBox.shrink();
              }
              return _AppLovinMaxNativeView(
                nativeId: AdManager().appLovinNativeId,
                instanceKey: this,
                placement: widget.placement,
                customBuilder: useCustom ? customBuilder : null,
              );
            },
          );
        });
      },
    );
  }
}

class _NativeContainer extends StatelessWidget {
  const _NativeContainer({
    required this.isLoaded,
    required this.child,
    required this.height,
  });

  final ValueListenable<bool> isLoaded;
  final Widget Function() child;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isLoaded,
      builder: (context, loaded, _) {
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
                    : const ShimmerView(cornerRadius: 2, width: 20, height: 13),
              ),
              // T62 — `child()` (MaxNativeAdView) must always be mounted,
              // not gated behind `loaded`: `loaded` is only ever flipped
              // true BY MaxNativeAdView's own onAdLoadedCallback, so gating
              // its mount behind that same flag is a deadlock — nothing
              // else can ever set it (AppLovin's preloadNative() is a
              // documented no-op). The shimmer is a visual overlay while
              // loading, not a substitute for mounting the real view.
              SizedBox(
                width: double.infinity,
                height: height,
                child: Stack(
                  children: [
                    child(),
                    if (!loaded)
                      ShimmerView(
                          cornerRadius: 0,
                          width: double.infinity,
                          height: height),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// AppLovin only — self-contained `MaxNativeAdView` with a fixed asset
/// layout. Unlike [_AppLovinMaxMrecView] (mrec_ad_widget.dart), this drives
/// [AdProviderAdapter.native]'s `isLoaded`/`hasError` directly from its own
/// listener callbacks — the adapter has no load flow of its own for native.
class _AppLovinMaxNativeView extends StatelessWidget {
  const _AppLovinMaxNativeView({
    required this.nativeId,
    required this.instanceKey,
    required this.placement,
    this.customBuilder,
  });

  final String nativeId;
  final AdPlacement placement;
  final CustomNativeAdBuilder? customBuilder;

  /// T65 (phase 1) — identifies which mounted [NativeAdWidget] this view
  /// belongs to, so its load/error callbacks update only ITS OWN
  /// isLoaded/hasError notifiers instead of a bundle shared across every
  /// simultaneous native ad on screen.
  final Object instanceKey;

  @override
  Widget build(BuildContext context) {
    // Round-46 audit fix (R46-03) — captured once per build, at the same
    // moment `instanceKey` is bound into these closures. `isNativeInstanceDisposed`
    // is a per-`AppLovinAdapter`-instance tombstone set, so after
    // `AdManager.destroy()` + a fresh `initialize()`, a late callback still
    // carrying the OLD adapter's `instanceKey` finds an empty tombstone set
    // on the NEW adapter and would otherwise pass the disposed check —
    // landing on, and contaminating, a brand-new session. Requiring the
    // callback's adapter to still be `identical` to the one that was
    // current when this listener was built closes that gap.
    final capturedAdapter = AdManager().adapter;
    return MaxNativeAdView(
      adUnitId: nativeId,
      listener: NativeAdListener(
        onAdLoadedCallback: (ad) {
          try {
            SafeLogger.d(
                'NativeAdWidget', 'MaxNativeAdView ✅ ${ad.networkName}');
            // N4: check isInitialised before writing — a disposed adapter
            // (re-init/destroy race) has already torn down its notifiers,
            // and this platform-view callback can fire after that.
            final adapter = AdManager().adapter;
            if (adapter == null || !adapter.isInitialised) return;
            // Round-65 audit fix (R65-01) — see build()'s `capturedAdapter`
            // doc comment: unlike a same-adapter per-key dispose (caught by
            // the disposed-sentinel throw below), a destroy()+re-init swap
            // hands us a DIFFERENT adapter whose registry never heard of
            // `instanceKey` — it would silently create a fresh, live entry
            // for it instead of throwing, contaminating the new session.
            if (!identical(adapter, capturedAdapter)) return;
            adapter.native(instanceKey).isLoaded.value = true;
            adapter.native(instanceKey).clearError();
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdLoadedCallback: notifier disposed mid-flight? $e');
          }
        },
        onAdLoadFailedCallback: (id, err) {
          try {
            SafeLogger.d('NativeAdWidget', 'MaxNativeAdView ❌ ${err.code}');
            final adapter = AdManager().adapter;
            if (adapter == null || !adapter.isInitialised) return;
            // Round-65 audit fix (R65-01) — see onAdLoadedCallback's
            // matching guard above.
            if (!identical(adapter, capturedAdapter)) return;
            adapter.native(instanceKey).markError();
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdLoadFailedCallback: notifier disposed mid-flight? $e');
          }
        },
        onAdClickedCallback: (ad) {
          try {
            final adapter = AdManager().adapter;
            if (adapter == null || !adapter.isInitialised) return;
            // Round-46 audit fix (R46-03) — see this build()'s
            // `capturedAdapter` doc comment: a late callback whose adapter
            // has since been replaced (destroy() + re-initialize()) must
            // not land on the new session at all, regardless of the new
            // adapter's own tombstone state.
            if (!identical(adapter, capturedAdapter)) return;
            // Round-45 audit fix (R45-02) — same reasoning as
            // onAdRevenuePaidCallback below: this writes into shared state
            // (AdSafetyConfig's global click/invalid-traffic counters, plus
            // the shared eventSink) rather than a per-instanceKey notifier,
            // so a click delivered after this instance was disposed (user
            // navigated away between tap and the native callback arriving)
            // wouldn't throw and get caught below — it would silently count
            // against global click/safety state for an instance that no
            // longer exists.
            if (adapter is AppLovinAdapter &&
                adapter.isNativeInstanceDisposed(instanceKey)) {
              return;
            }
            SafeLogger.d('NativeAdWidget', 'MaxNativeAdView 🎯 click');
            AdSafetyConfig.recordAdClick();
            adapter.eventSink?.call(AdClickEvent(
              providerTag: '[AppLovin]',
              type: AdSlotType.native,
              placement: placement,
            ));
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdClickedCallback: disposed mid-flight? $e');
          }
        },
        // Round-32 audit fix (MAJOR) — AppLovin native previously had NO
        // revenue signal wired at all (unlike AdMob's native, which wires
        // onPaidEvent): 0 AdRevenueEvent, 0 impression count, for the
        // entire lifetime of the SDK on this format. NativeAdListener
        // supports onAdRevenuePaidCallback same as the ad-view listeners
        // above; it was just never given one.
        onAdRevenuePaidCallback: (ad) {
          try {
            final adapter = AdManager().adapter;
            if (adapter == null || !adapter.isInitialised) return;
            // Round-46 audit fix (R46-03) — see build()'s `capturedAdapter`
            // doc comment.
            if (!identical(adapter, capturedAdapter)) return;
            // Round-33 (R33-03) — unlike onAdLoaded/onAdFailedToLoad above,
            // this callback writes into shared state (AdSafetyConfig,
            // eventSink) rather than a per-instanceKey notifier, so a late
            // callback for an already-disposed instanceKey wouldn't throw
            // and get caught below — it would just silently double-count.
            if (adapter is AppLovinAdapter &&
                adapter.isNativeInstanceDisposed(instanceKey)) {
              return;
            }
            SafeLogger.d('NativeAdWidget', 'MaxNativeAdView 💰 impression');
            AdSafetyConfig.recordBannerImpression();
            final sink = adapter.eventSink;
            sink?.call(AdImpressionEvent(
              providerTag: '[AppLovin]',
              type: AdSlotType.native,
              placement: placement,
            ));
            final revenue = appLovinRevenueEvent(ad,
                type: AdSlotType.native, placement: placement);
            if (revenue != null) sink?.call(revenue);
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdRevenuePaidCallback: disposed mid-flight? $e');
          }
        },
      ),
      child: customBuilder == null
          ? _standardLayout()
          // T228 — the host's builder never sees/places the attribution
          // badge; the SDK overlays it on top unconditionally so a custom
          // layout can never accidentally omit it (fail-safe already ruled
          // out the "too small" case one level up in NativeAdWidget).
          : Stack(
              children: [
                // Reserve the badge's top-right square ourselves instead of
                // trusting every host builder to remember it. In ordinary
                // layouts the host content therefore cannot cover/clip the
                // SDK-owned attribution overlay; the size guard one level up
                // falls back before this padding can consume the whole view.
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      top: kMinNativeAdAttributionSize,
                      right: kMinNativeAdAttributionSize,
                    ),
                    child: customBuilder!(context),
                  ),
                ),
                const Positioned(
                  top: 0,
                  right: 0,
                  child: MaxNativeAdOptionsView(
                    width: kMinNativeAdAttributionSize,
                    height: kMinNativeAdAttributionSize,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _standardLayout() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const MaxNativeAdIconView(width: 40, height: 40),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  MaxNativeAdTitleView(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  MaxNativeAdStarRatingView(),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // Audit round 42, BLOCKER — AppLovin's own native-ad guide
            // requires this view (the privacy-info/AdChoices-equivalent
            // icon) in every custom native layout; omitting it is a
            // policy violation, not a placement preference. Position
            // matches AppLovin's own reference example (top-right,
            // alongside title/rating).
            const MaxNativeAdOptionsView(width: 20, height: 20),
          ],
        ),
        const SizedBox(height: 8),
        const Expanded(child: MaxNativeAdMediaView(width: double.infinity)),
        const SizedBox(height: 8),
        const MaxNativeAdBodyView(
            maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: MaxNativeAdCallToActionView(),
        ),
      ],
    );
  }
}
