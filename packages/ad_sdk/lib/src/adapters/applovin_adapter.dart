import 'dart:async';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/ad_config.dart';
import '../core/ad_provider_adapter.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';

/// AppLovin MAX implementation of [AdProviderAdapter].
class AppLovinAdapter implements AdProviderAdapter {
  AppLovinAdapter();

  @override
  String get tag => '[AppLovin]';

  static const String _logTag = 'AppLovinAdapter';

  // ignore: unused_field
  AdConfig? _config;
  AppLovinConfig? _max;

  @override
  AdEventSink? eventSink;

  void _emit(AdEvent e) => eventSink?.call(e);

  /// AppLovin returns revenue on every load callback via `MaxAd.revenue`.
  /// `0` = no revenue / test mode → skip.
  void _emitRevenueIfPresent(MaxAd ad, AdSlotType type, AdPlacement placement) {
    final amount = ad.revenue;
    if (amount <= 0) return;
    _emit(AdRevenueEvent(
      providerTag: tag,
      type: type,
      placement: placement,
      valueMicros: (amount * 1000000).round(),
      currencyCode: 'USD',
      networkName: ad.networkName,
      precision: ad.revenuePrecision,
    ));
  }

  @override
  bool get isInitialised => _max != null;

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  @override
  final BannerListenables banner = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );

  final ValueNotifier<AdViewId?> _bannerAdViewId = ValueNotifier<AdViewId?>(null);

  @override
  ValueListenable<Object?> get appLovinBannerAdViewId => _bannerAdViewId;

  @override
  String? get appLovinBannerId => _max?.bannerId;

  void Function(bool dismissed)? _appOpenDismiss;
  void Function(bool loaded)? _appOpenLoadCb;
  void Function(bool shown)? _interstitialDone;
  void Function(RewardResult result)? _rewardedDone;

  Timer? _appOpenShowTimeout;

  bool _bannerRoutePaused = false;

  @override
  bool get bannerRoutePaused => _bannerRoutePaused;

  @override
  void setBannerRoutePaused(bool paused) {
    _bannerRoutePaused = paused;
  }

  @override
  Future<bool> initialize(AdConfig config, {String deviceGaid = ''}) async {
    final cfg = config.appLovin;
    if (cfg == null) {
      SafeLogger.e(_logTag, 'initialize: AppLovinConfig is null — aborted');
      return false;
    }
    _config = config;
    _max = cfg;
    SafeLogger.d(_logTag, 'initialize $tag wiring listeners…');
    _wireAppOpenListener(cfg.appOpenId);
    _wireInterstitialListener(cfg.interstitialId);
    _wireRewardedListener(cfg.rewardedId);
    try {
      await AppLovinMAX.initialize(cfg.sdkKey);
      SafeLogger.d(_logTag, 'initialize $tag ✅ SDK ready');

      // Register THIS device as a test device in debug builds — required
      // by AppLovin to avoid serving real (revenue-counting) ads to the
      // developer. Failing to do so risks account suspension. Preserves
      // 1.x behaviour exactly.
      if (kDebugMode && deviceGaid.isNotEmpty) {
        try {
          AppLovinMAX.setTestDeviceAdvertisingIds([deviceGaid]);
          SafeLogger.d(_logTag, 'AppLovin test device registered: $deviceGaid');
        } catch (e) {
          SafeLogger.w(_logTag, 'setTestDeviceAdvertisingIds failed: $e');
        }
      }
      return true;
    } catch (e, st) {
      SafeLogger.e(_logTag, 'initialize $tag FAILED: $e\n$st');
      _max = null;
      _config = null;
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    SafeLogger.d(_logTag, 'dispose() $tag — clearing listeners + timers');
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = null;

    // Order matters: clear native listeners FIRST so any callback fired
    // mid-destruction (e.g. destroyWidgetAdView triggers an
    // `onAdDisplayFailedCallback`) is silently dropped instead of
    // mutating slot state on a half-disposed adapter.
    try {
      AppLovinMAX.setAppOpenAdListener(null);
      AppLovinMAX.setInterstitialListener(null);
      AppLovinMAX.setRewardedAdListener(null);
      AppLovinMAX.setWidgetAdViewAdListener(null);
    } catch (e) {
      SafeLogger.w(_logTag, 'dispose() listener clear threw: $e');
    }

    // Now destroy the native widget AdView. Without this the native side
    // keeps the previous banner alive across destroy → re-init cycles.
    final oldId = _bannerAdViewId.value;
    if (oldId != null) {
      try {
        await AppLovinMAX.destroyWidgetAdView(oldId);
      } catch (e) {
        SafeLogger.w(_logTag, 'destroyWidgetAdView threw: $e');
      }
    }
    _appOpenDismiss?.call(false);
    _appOpenDismiss = null;
    _appOpenLoadCb?.call(false);
    _appOpenLoadCb = null;
    _interstitialDone?.call(false);
    _interstitialDone = null;
    _rewardedDone?.call(RewardResult.skipped);
    _rewardedDone = null;
    appOpenSlot.reset();
    interstitialSlot.reset();
    rewardedSlot.reset();
    bannerSlot.reset();
    banner.isLoaded.value = false;
    banner.hasError.value = false;
    banner.adSize.value = null;
    banner.autoRefreshEnabled.value = true;
    banner.visible.value = true;
    _bannerAdViewId.value = null;
    _bannerRoutePaused = false;
    _max = null;
    _config = null;
  }

  // ─── App Open ─────────────────────────────────────────────────────────────

  void _wireAppOpenListener(String unitId) {
    AppLovinMAX.setAppOpenAdListener(AppOpenAdListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_logTag, 'appOpen $tag ✅ loaded');
        appOpenSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.w(_logTag, 'appOpen $tag ❌ load failed code=${err.code}');
        appOpenSlot.markFailed();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
          success: false,
          errorCode: err.code.value,
        ));
      },
      onAdDisplayedCallback: (ad) => SafeLogger.d(_logTag, 'appOpen $tag ✅ displayed'),
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(ad, AdSlotType.appOpen, AdPlacement.splash);
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.w(_logTag, 'appOpen $tag ❌ display failed: ${err.message}');
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        appOpenSlot.markShowFailed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(false);
        if (appOpenSlot.beginLoad()) {
          try {
            AppLovinMAX.loadAppOpenAd(unitId);
          } catch (e) {
            SafeLogger.e(_logTag, 'reload appOpen threw: $e');
            appOpenSlot.markFailed();
          }
        }
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_logTag, 'appOpen $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
        ));
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_logTag, 'appOpen $tag 👋 hidden');
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        appOpenSlot.markDismissed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(true);
        if (appOpenSlot.beginLoad()) {
          try {
            AppLovinMAX.loadAppOpenAd(unitId);
          } catch (e) {
            SafeLogger.e(_logTag, 'reload appOpen threw: $e');
            appOpenSlot.markFailed();
          }
        }
      },
    ));
  }

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {
    final cfg = _max;
    if (cfg == null) {
      onAdLoaded?.call(false);
      return;
    }
    if (appOpenSlot.isReady) {
      onAdLoaded?.call(true);
      return;
    }
    if (!appOpenSlot.beginLoad()) {
      onAdLoaded?.call(false);
      return;
    }
    final prev = _appOpenLoadCb;
    if (prev != null) prev(false);
    _appOpenLoadCb = onAdLoaded;
    appOpenSlot.pendingCallback = (success) {
      final cb = _appOpenLoadCb;
      _appOpenLoadCb = null;
      cb?.call(success);
    };
    SafeLogger.d(_logTag, 'loadAppOpen $tag 🔄 id=${cfg.appOpenId}');
    try {
      AppLovinMAX.loadAppOpenAd(cfg.appOpenId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadAppOpen $tag THREW: $e\n$st');
      appOpenSlot.markFailed();
    }
  }

  @override
  Future<void> showAppOpen({required void Function(bool dismissed) onDismiss}) async {
    final cfg = _max;
    if (cfg == null) {
      onDismiss(false);
      return;
    }
    if (!appOpenSlot.isReady) {
      SafeLogger.w(_logTag, 'showAppOpen $tag ⚠️ not ready');
      onDismiss(false);
      return;
    }
    if (!appOpenSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showAppOpen $tag ⚠️ already showing');
      onDismiss(false);
      return;
    }
    final old = _appOpenDismiss;
    _appOpenDismiss = null;
    if (old != null) old(false);
    _appOpenDismiss = onDismiss;

    SafeLogger.d(_logTag, 'showAppOpen $tag → AppLovinMAX.showAppOpenAd');
    try {
      AppLovinMAX.showAppOpenAd(cfg.appOpenId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showAppOpen $tag THREW: $e\n$st');
      appOpenSlot.markShowFailed();
      final cb = _appOpenDismiss;
      _appOpenDismiss = null;
      cb?.call(false);
      return;
    }

    _appOpenShowTimeout?.cancel();
    final captured = onDismiss;
    _appOpenShowTimeout = Timer(const Duration(seconds: 10), () {
      _appOpenShowTimeout = null;
      if (_appOpenDismiss == captured && appOpenSlot.isShowing) {
        SafeLogger.e(_logTag, 'showAppOpen $tag ⏰ TIMEOUT 10s — force dismiss(false)');
        appOpenSlot.markShowFailed();
        _appOpenDismiss = null;
        captured(false);
      }
    });
  }

  // ─── Interstitial ─────────────────────────────────────────────────────────

  void _wireInterstitialListener(String unitId) {
    AppLovinMAX.setInterstitialListener(InterstitialListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_logTag, 'inter $tag ✅ loaded');
        interstitialSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.w(_logTag, 'inter $tag ❌ load failed code=${err.code}');
        interstitialSlot.markFailed();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: false,
          errorCode: err.code.value,
        ));
      },
      onAdDisplayedCallback: (ad) => SafeLogger.d(_logTag, 'inter $tag ✅ displayed'),
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(ad, AdSlotType.interstitial, AdPlacement.unspecified);
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.w(_logTag, 'inter $tag ❌ display failed: ${err.message}');
        interstitialSlot.markShowFailed();
        final cb = _interstitialDone;
        _interstitialDone = null;
        cb?.call(false);
        if (interstitialSlot.beginLoad()) {
          try {
            AppLovinMAX.loadInterstitial(unitId);
          } catch (e) {
            SafeLogger.e(_logTag, 'reload inter threw: $e');
            interstitialSlot.markFailed();
          }
        }
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_logTag, 'inter $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
        ));
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_logTag, 'inter $tag 👋 hidden');
        interstitialSlot.markDismissed();
        final cb = _interstitialDone;
        _interstitialDone = null;
        cb?.call(true);
        if (interstitialSlot.beginLoad()) {
          try {
            AppLovinMAX.loadInterstitial(unitId);
          } catch (e) {
            SafeLogger.e(_logTag, 'reload inter threw: $e');
            interstitialSlot.markFailed();
          }
        }
      },
    ));
  }

  @override
  Future<void> loadInterstitial() async {
    final cfg = _max;
    if (cfg == null) return;
    if (interstitialSlot.isReady) return;
    if (!interstitialSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadInterstitial $tag 🔄');
    try {
      AppLovinMAX.loadInterstitial(cfg.interstitialId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadInterstitial $tag THREW: $e\n$st');
      interstitialSlot.markFailed();
    }
  }

  @override
  Future<void> showInterstitial({required void Function(bool shown) onDone}) async {
    final cfg = _max;
    if (cfg == null) {
      onDone(false);
      return;
    }
    if (!interstitialSlot.isReady) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ not ready');
      onDone(false);
      return;
    }
    if (!interstitialSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ already showing');
      onDone(false);
      return;
    }
    final old = _interstitialDone;
    _interstitialDone = null;
    if (old != null) old(false);
    _interstitialDone = onDone;
    try {
      AppLovinMAX.showInterstitial(cfg.interstitialId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showInterstitial $tag THREW: $e\n$st');
      interstitialSlot.markShowFailed();
      final cb = _interstitialDone;
      _interstitialDone = null;
      cb?.call(false);
    }
  }

  // ─── Rewarded ─────────────────────────────────────────────────────────────

  void _wireRewardedListener(String unitId) {
    AppLovinMAX.setRewardedAdListener(RewardedAdListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_logTag, 'rewarded $tag ✅ loaded');
        rewardedSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.w(_logTag, 'rewarded $tag ❌ load failed code=${err.code}');
        rewardedSlot.markFailed();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
          success: false,
          errorCode: err.code.value,
        ));
      },
      onAdDisplayedCallback: (ad) => SafeLogger.d(_logTag, 'rewarded $tag ✅ displayed'),
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(ad, AdSlotType.rewarded, AdPlacement.unspecified);
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.w(_logTag, 'rewarded $tag ❌ display failed: ${err.message}');
        rewardedSlot.markShowFailed();
        final cb = _rewardedDone;
        _rewardedDone = null;
        cb?.call(RewardResult.skipped);
        if (rewardedSlot.beginLoad()) {
          try {
            AppLovinMAX.loadRewardedAd(unitId);
          } catch (e) {
            SafeLogger.e(_logTag, 'reload rewarded threw: $e');
            rewardedSlot.markFailed();
          }
        }
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_logTag, 'rewarded $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
        ));
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_logTag, 'rewarded $tag 👋 hidden');
        rewardedSlot.markDismissed();
        final cb = _rewardedDone;
        _rewardedDone = null;
        cb?.call(RewardResult.skipped);
        if (rewardedSlot.beginLoad()) {
          try {
            AppLovinMAX.loadRewardedAd(unitId);
          } catch (e) {
            SafeLogger.e(_logTag, 'reload rewarded threw: $e');
            rewardedSlot.markFailed();
          }
        }
      },
      onAdReceivedRewardCallback: (ad, reward) {
        SafeLogger.d(_logTag, 'rewarded $tag 🏆 ${reward.label}/${reward.amount}');
        final cb = _rewardedDone;
        _rewardedDone = null;
        cb?.call(RewardResult(
          earned: true,
          label: reward.label,
          amount: reward.amount,
        ));
      },
    ));
  }

  @override
  Future<void> loadRewarded() async {
    final cfg = _max;
    if (cfg == null) return;
    if (rewardedSlot.isReady) return;
    if (!rewardedSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadRewarded $tag 🔄');
    try {
      AppLovinMAX.loadRewardedAd(cfg.rewardedId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadRewarded $tag THREW: $e\n$st');
      rewardedSlot.markFailed();
    }
  }

  @override
  Future<void> showRewarded({required void Function(RewardResult result) onDone}) async {
    final cfg = _max;
    if (cfg == null) {
      onDone(RewardResult.skipped);
      return;
    }
    if (!rewardedSlot.isReady) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ not ready');
      onDone(RewardResult.skipped);
      return;
    }
    if (!rewardedSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ already showing');
      onDone(RewardResult.skipped);
      return;
    }
    final old = _rewardedDone;
    _rewardedDone = null;
    if (old != null) old(RewardResult.skipped);
    _rewardedDone = onDone;
    try {
      AppLovinMAX.showRewardedAd(cfg.rewardedId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showRewarded $tag THREW: $e\n$st');
      rewardedSlot.markShowFailed();
      final cb = _rewardedDone;
      _rewardedDone = null;
      cb?.call(RewardResult.skipped);
    }
  }

  // ─── Banner ──────────────────────────────────────────────────────────────

  @override
  Future<void> preloadBanner() async {
    final cfg = _max;
    if (cfg == null) return;
    SafeLogger.d(_logTag, 'preloadBanner $tag 🔄 id=${cfg.bannerId}');

    AppLovinMAX.setWidgetAdViewAdListener(WidgetAdViewAdListener(
      onAdLoadedCallback: (ad) {
        final isInitial = !banner.isLoaded.value;
        SafeLogger.d(
          _logTag,
          'banner $tag ${isInitial ? '✅ initial loaded' : '♻️ refreshed'} '
          'adViewId=${ad.adViewId} network=${ad.networkName}',
        );
        banner.isLoaded.value = true;
        banner.hasError.value = false;
        final adSize = ad.size;
        if (adSize != null) {
          final sz = Size(adSize.width.toDouble(), adSize.height.toDouble());
          if (banner.adSize.value != sz) banner.adSize.value = sz;
        }
        bannerSlot.markReady();
        if (isInitial) AdSafetyConfig.recordBannerImpression();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.banner,
          placement: AdPlacement.unspecified,
          success: true,
        ));
        _emitRevenueIfPresent(ad, AdSlotType.banner, AdPlacement.unspecified);
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.w(_logTag, 'banner $tag ❌ load failed code=${err.code}');
        banner.isLoaded.value = false;
        banner.hasError.value = true;
        bannerSlot.markFailed();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.banner,
          placement: AdPlacement.unspecified,
          success: false,
          errorCode: err.code.value,
        ));
      },
    ));

    try {
      final adViewId = await AppLovinMAX.preloadWidgetAdView(
        cfg.bannerId,
        AdFormat.banner,
      );
      if (adViewId == null) {
        SafeLogger.w(_logTag, 'banner $tag ❌ preload returned null adViewId');
        banner.hasError.value = true;
        bannerSlot.markFailed();
        return;
      }
      SafeLogger.d(_logTag, 'banner $tag ✅ preload started adViewId=$adViewId');
      _bannerAdViewId.value = adViewId;
    } catch (e, st) {
      SafeLogger.e(_logTag, 'banner $tag preload THREW: $e\n$st');
      banner.hasError.value = true;
      bannerSlot.markFailed();
    }
  }

  @override
  Future<void> loadBannerIfNeeded(double widthPx) async {
    // AppLovin uses preload — width-aware loading not needed.
  }

  @override
  Widget? buildAdmobBannerView() => null;

  @override
  void onAppPaused() {
    if (_bannerAdViewId.value != null) {
      banner.autoRefreshEnabled.value = false;
    }
  }

  @override
  void onAppResumed() {
    if (banner.hasError.value) {
      banner.hasError.value = false;
      _bannerAdViewId.value = null;
      banner.autoRefreshEnabled.value = true;
      preloadBanner();
    } else if (_bannerAdViewId.value != null && !_bannerRoutePaused) {
      banner.autoRefreshEnabled.value = true;
    }
  }
}
