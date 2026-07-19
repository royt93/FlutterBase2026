import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
/// Place anywhere in your screen tree:
/// ```dart
/// Column(children: [buildNative(), ...])   // inside an AdScreenState
/// // or directly:
/// const NativeAdWidget()
/// ```
class NativeAdWidget extends StatefulWidget {
  const NativeAdWidget({super.key});

  @override
  State<NativeAdWidget> createState() => _NativeAdWidgetState();
}

class _NativeAdWidgetState extends State<NativeAdWidget> {
  static const String _tag = 'NativeAdWidget';
  static const double _height = 320;

  final ValueNotifier<bool> _allowed = ValueNotifier<bool>(false);
  bool _initScheduled = false;

  @override
  void initState() {
    super.initState();
    SafeLogger.d(_tag, 'initState');
    _initNative();
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
    if (!mgr.canLoadNative()) {
      SafeLogger.d(_tag, '_initNative ⏭️ cooldown');
      return;
    }
    mgr.recordNativeLoad();
    _allowed.value = true;

    if (mgr.isAdMobProvider) {
      mgr.loadAdmobNativeIfNeeded();
    } else {
      SafeLogger.d(
          _tag, '_initNative [AppLovin] MaxNativeAdView loads on mount');
    }
  }

  @override
  void dispose() {
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
      valueListenable: AdManager().nativeHasError,
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: AdManager().nativeIsLoaded,
          builder: (context, loaded, _) {
            if (!loaded) {
              return const ShimmerView(
                  cornerRadius: 0, width: double.infinity, height: _height);
            }
            final view = AdManager().admobNativeView;
            if (view == null) {
              return const SizedBox(height: _height, width: double.infinity);
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
      valueListenable: AdManager().nativeHasError,
      builder: (context, hasError, _) {
        if (hasError) return const SizedBox.shrink();
        return _NativeContainer(
          isLoaded: AdManager().nativeIsLoaded,
          child: () =>
              _AppLovinMaxNativeView(nativeId: AdManager().appLovinNativeId),
        );
      },
    );
  }
}

class _NativeContainer extends StatelessWidget {
  const _NativeContainer({
    required this.isLoaded,
    required this.child,
  });

  final ValueListenable<bool> isLoaded;
  final Widget Function() child;

  static const double _height = 320;

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
              SizedBox(
                width: double.infinity,
                height: _height,
                child: loaded
                    ? child()
                    : const ShimmerView(
                        cornerRadius: 0,
                        width: double.infinity,
                        height: _height),
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
  const _AppLovinMaxNativeView({required this.nativeId});

  final String nativeId;

  @override
  Widget build(BuildContext context) {
    return MaxNativeAdView(
      adUnitId: nativeId,
      listener: NativeAdListener(
        onAdLoadedCallback: (ad) {
          try {
            SafeLogger.d(
                'NativeAdWidget', 'MaxNativeAdView ✅ ${ad.networkName}');
            final adapter = AdManager().adapter;
            adapter?.native.isLoaded.value = true;
            adapter?.native.hasError.value = false;
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdLoadedCallback: notifier disposed mid-flight? $e');
          }
        },
        onAdLoadFailedCallback: (id, err) {
          try {
            SafeLogger.d('NativeAdWidget', 'MaxNativeAdView ❌ ${err.code}');
            AdManager().adapter?.native.hasError.value = true;
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdLoadFailedCallback: notifier disposed mid-flight? $e');
          }
        },
        onAdClickedCallback: (ad) {
          try {
            SafeLogger.d('NativeAdWidget', 'MaxNativeAdView 🎯 click');
            AdSafetyConfig.recordAdClick();
            AdManager().adapter?.eventSink?.call(AdClickEvent(
                  providerTag: '[AppLovin]',
                  type: AdSlotType.native,
                  placement: AdPlacement.unspecified,
                ));
          } catch (e) {
            SafeLogger.e('NativeAdWidget',
                'onAdClickedCallback: disposed mid-flight? $e');
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
