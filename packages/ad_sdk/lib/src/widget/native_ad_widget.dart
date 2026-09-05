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
/// Place anywhere in your screen tree:
/// ```dart
/// Column(children: [buildNative(), ...])   // inside an AdScreenState
/// // or directly:
/// const NativeAdWidget()
/// // in-feed / ListView (T73) — small template, no explicit height needed:
/// const NativeAdWidget(templateType: TemplateType.small)
/// // or fully custom height on either provider:
/// const NativeAdWidget(height: 120)
/// ```
class NativeAdWidget extends StatefulWidget {
  const NativeAdWidget({
    super.key,
    this.templateType = TemplateType.medium,
    this.height,
    this.placement = AdPlacement.unspecified,
  });

  /// T107 — tags this instance for analytics/per-placement caps, same as
  /// the `placement` param on `showInterstitialAd`/`showRewardedAd`.
  final AdPlacement placement;

  /// AdMob's built-in native template layout. Ignored by AppLovin (no
  /// equivalent concept — `MaxNativeAdView` is a custom-drawn layout).
  /// Also picks this widget's default [height] when that's not set
  /// explicitly: 320 for [TemplateType.medium], 90 for [TemplateType.small].
  final TemplateType templateType;

  /// Overrides the default height implied by [templateType] — applies to
  /// both providers' layout, since AppLovin has no template concept at all.
  final double? height;

  @override
  State<NativeAdWidget> createState() => _NativeAdWidgetState();
}

class _NativeAdWidgetState extends State<NativeAdWidget> {
  static const String _tag = 'NativeAdWidget';

  double get _height =>
      widget.height ??
      (widget.templateType == TemplateType.small ? 90 : 320);

  final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);
  bool _initScheduled = false;

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
  void initState() {
    super.initState();
    SafeLogger.d(_tag, 'initState');
    _initNative();
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
      _initNative();
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
          !mgr.isVIPMember()) {
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
      mgr.loadAdmobNativeIfNeeded(this, templateType: widget.templateType);
    } else {
      SafeLogger.d(
          _tag, '_initNative [AppLovin] MaxNativeAdView loads on mount');
    }
  }

  @override
  void dispose() {
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
      builder: (context, _, __) {
        if (!_allowed.value && !_initScheduled && AdManager().isInitialised) {
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
        return _NativeContainer(
          isLoaded: AdManager().nativeIsLoaded(this),
          height: _height,
          child: () =>
              _AppLovinMaxNativeView(
                  nativeId: AdManager().appLovinNativeId,
                  instanceKey: this,
                  placement: widget.placement),
        );
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
  });

  final String nativeId;
  final AdPlacement placement;

  /// T65 (phase 1) — identifies which mounted [NativeAdWidget] this view
  /// belongs to, so its load/error callbacks update only ITS OWN
  /// isLoaded/hasError notifiers instead of a bundle shared across every
  /// simultaneous native ad on screen.
  final Object instanceKey;

  @override
  Widget build(BuildContext context) {
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
            adapter.native(instanceKey).markError();
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdLoadFailedCallback: notifier disposed mid-flight? $e');
          }
        },
        onAdClickedCallback: (ad) {
          try {
            SafeLogger.d('NativeAdWidget', 'MaxNativeAdView 🎯 click');
            AdSafetyConfig.recordAdClick();
            final adapter = AdManager().adapter;
            if (adapter == null || !adapter.isInitialised) return;
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
      child: Column(
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
      ),
    );
  }
}
