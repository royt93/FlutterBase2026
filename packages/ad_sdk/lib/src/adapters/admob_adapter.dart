import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';
import '../core/ad_provider_adapter.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';

/// AdMob (Google Mobile Ads) implementation of [AdProviderAdapter].
///
/// Owns the 4 ad-unit objects (`AppOpenAd`, `InterstitialAd`, `RewardedAd`,
/// `BannerAd`) and their state machines. All callbacks go through [AdSlot]
/// transitions instead of hand-managed bool flags.
class AdMobAdapter implements AdProviderAdapter {
  AdMobAdapter();

  @override
  String get tag => '[AdMob]';

  static const String _logTag = 'AdMobAdapter';

  // ignore: unused_field
  AdConfig? _config;
  AdMobConfig? _admob;

  @override
  AdEventSink? eventSink;

  void _emit(AdEvent e) => eventSink?.call(e);

  /// Wires `OnPaidEventCallback` for the given native ad — emits AdRevenueEvent.
  /// Used for AppOpen / Interstitial / Rewarded (subclasses of [AdWithoutView]
  /// — they expose `onPaidEvent` as a settable property).
  ///
  /// Banner ([AdWithView]) does NOT expose this setter — its paid-event
  /// callback must be passed via [BannerAdListener] at construction. See
  /// [_paidEventForBanner] below.
  void _wirePaidEvent(dynamic ad, AdSlotType type, AdPlacement placement) {
    try {
      ad.onPaidEvent = (Ad _, double valueMicros, PrecisionType precision, String currencyCode) {
        _emit(AdRevenueEvent(
          providerTag: tag,
          type: type,
          placement: placement,
          valueMicros: valueMicros.toInt(),
          currencyCode: currencyCode,
          precision: precision.name,
        ));
      };
    } catch (e) {
      SafeLogger.w(_logTag, 'paid-event wire failed for $type: $e');
    }
  }

  /// Constructor-time paid-event callback for banner — used in
  /// [BannerAdListener] since [BannerAd] inherits from [AdWithView] which
  /// doesn't expose `onPaidEvent` as a setter.
  OnPaidEventCallback _paidEventForBanner(AdPlacement placement) =>
      (Ad _, double valueMicros, PrecisionType precision, String currencyCode) {
        _emit(AdRevenueEvent(
          providerTag: tag,
          type: AdSlotType.banner,
          placement: placement,
          valueMicros: valueMicros.toInt(),
          currencyCode: currencyCode,
          precision: precision.name,
        ));
      };

  @override
  bool get isInitialised => _admob != null;

  // ─── Slots ────────────────────────────────────────────────────────────────

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  // ─── Banner listenables ───────────────────────────────────────────────────

  @override
  final BannerListenables banner = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );

  // ─── Native ad objects ────────────────────────────────────────────────────

  AppOpenAd? _appOpenAd;
  InterstitialAd? _interstitialAd;
  RewardedAd? _rewardedAd;
  BannerAd? _bannerAd;

  // ─── Pending callbacks (one per slot at most) ─────────────────────────────
  void Function(bool dismissed)? _appOpenDismiss;
  void Function(bool shown)? _interstitialDone;
  void Function(RewardResult result)? _rewardedDone;

  /// Safety watchdog for App Open show. GMA's `FullScreenContentCallback` is
  /// reliable, but on the rare occasion neither `onAdDismissed` nor
  /// `onAdFailedToShow` fires (some mediation adapters), the resume path has no
  /// other timer to recover it → the caller would hang forever. Mirrors the
  /// AppLovin adapter's hard-cap watchdog.
  Timer? _appOpenShowTimeout;
  static const Duration _appOpenShowHardCap = Duration(seconds: 90);

  bool _bannerRoutePaused = false;

  @override
  bool get bannerRoutePaused => _bannerRoutePaused;

  @override
  void setBannerRoutePaused(bool paused) {
    _bannerRoutePaused = paused;
  }

  @override
  String? get appLovinBannerId => null; // AdMob only

  @override
  ValueListenable<Object?> get appLovinBannerAdViewId => _appLovinAdViewIdStub;
  static final ValueNotifier<Object?> _appLovinAdViewIdStub = ValueNotifier<Object?>(null);

  // ──────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<bool> initialize(AdConfig config, {String deviceGaid = ''}) async {
    final cfg = config.admob;
    if (cfg == null) {
      SafeLogger.e(_logTag, 'initialize: AdMobConfig is null — aborted');
      return false;
    }
    try {
      await MobileAds.instance.initialize();
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(testDeviceIds: cfg.testDeviceIds),
      );
      _config = config;
      _admob = cfg;
      SafeLogger.d(_logTag, 'initialize $tag ✅');
      return true;
    } catch (e, st) {
      SafeLogger.e(_logTag, 'initialize $tag FAILED: $e\n$st');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    SafeLogger.d(_logTag, 'dispose() $tag — releasing native resources');
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = null;
    _disposeAd(_appOpenAd, 'appOpen');
    _appOpenAd = null;
    _disposeAd(_interstitialAd, 'interstitial');
    _interstitialAd = null;
    _disposeAd(_rewardedAd, 'rewarded');
    _rewardedAd = null;
    try {
      _bannerAd?.dispose();
    } catch (e) {
      SafeLogger.w(_logTag, 'banner dispose threw: $e');
    }
    _bannerAd = null;

    // Fire any pending callbacks with `false` so callers don't hang.
    _appOpenDismiss?.call(false);
    _appOpenDismiss = null;
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
    _bannerRoutePaused = false;

    _admob = null;
    _config = null;
  }

  void _disposeAd(dynamic ad, String label) {
    if (ad == null) return;
    try {
      // Critical: null callback BEFORE dispose to avoid late callbacks
      // mutating state on a destroyed object (Fix #30 preserved).
      if (ad is AppOpenAd) ad.fullScreenContentCallback = null;
      if (ad is InterstitialAd) ad.fullScreenContentCallback = null;
      if (ad is RewardedAd) ad.fullScreenContentCallback = null;
      ad.dispose();
    } catch (e) {
      SafeLogger.w(_logTag, '$label dispose threw: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  APP OPEN
  // ──────────────────────────────────────────────────────────────────────────

  static const int _appOpenExpiryHours = 4;

  /// AdMob interstitial/rewarded content is valid for up to 1 hour after load
  /// (per Google's docs). Beyond that the cached ad is stale and `show()` will
  /// fail — so refuse to reuse it and load a fresh one instead.
  static const int _fullscreenExpiryHours = 1;

  /// Whether a cached ad loaded at [loadedAt] is still fresh enough to reuse.
  /// Returns false when never loaded (`null`). Exposed for tests.
  @visibleForTesting
  static bool isAdFresh(DateTime? loadedAt, int maxHours, {DateTime? now}) {
    if (loadedAt == null) return false;
    return (now ?? DateTime.now()).difference(loadedAt).inHours < maxHours;
  }

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {
    final cfg = _admob;
    if (cfg == null) {
      onAdLoaded?.call(false);
      return;
    }

    // Fresh ad already in slot? Reuse.
    if (_appOpenAd != null) {
      if (isAdFresh(appOpenSlot.lastLoadedAt, _appOpenExpiryHours)) {
        SafeLogger.d(_logTag, 'loadAppOpen $tag ⏭️ already fresh, reuse');
        onAdLoaded?.call(true);
        return;
      }
      SafeLogger.d(_logTag, 'loadAppOpen $tag ♻️ expired (>${_appOpenExpiryHours}h), disposing old');
      _disposeAd(_appOpenAd, 'appOpen-expired');
      _appOpenAd = null;
      appOpenSlot.lastLoadedAt = null;
    }

    if (!appOpenSlot.beginLoad()) {
      SafeLogger.d(_logTag, 'loadAppOpen $tag ⏭️ already loading/showing');
      onAdLoaded?.call(false);
      return;
    }
    appOpenSlot.pendingCallback = onAdLoaded;
    SafeLogger.d(_logTag, 'loadAppOpen $tag 🔄');

    try {
      await AppOpenAd.load(
        adUnitId: cfg.appOpenId,
        request: const AdRequest(),
        adLoadCallback: AppOpenAdLoadCallback(
          onAdLoaded: (ad) {
            SafeLogger.d(_logTag, 'loadAppOpen $tag ✅');
            _appOpenAd = ad;
            _wirePaidEvent(ad, AdSlotType.appOpen, AdPlacement.splash);
            appOpenSlot.markReady();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.appOpen,
              placement: AdPlacement.splash,
              success: true,
            ));
          },
          onAdFailedToLoad: (err) {
            SafeLogger.w(_logTag, 'loadAppOpen $tag ❌ code=${err.code} msg=${err.message}');
            _appOpenAd = null;
            appOpenSlot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.appOpen,
              placement: AdPlacement.splash,
              success: false,
              errorCode: err.code,
            ));
          },
        ),
      );
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadAppOpen $tag THREW: $e\n$st');
      _appOpenAd = null;
      appOpenSlot.markFailed();
    }
  }

  @override
  Future<void> showAppOpen({required void Function(bool dismissed) onDismiss}) async {
    final ad = _appOpenAd;
    if (ad == null || !appOpenSlot.isReady) {
      SafeLogger.w(_logTag, 'showAppOpen $tag ⚠️ not ready (state=${appOpenSlot.value})');
      onDismiss(false);
      return;
    }
    if (!appOpenSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showAppOpen $tag ⚠️ already showing');
      onDismiss(false);
      return;
    }
    _appOpenDismiss = onDismiss;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (a) {
        SafeLogger.d(_logTag, 'showAppOpen $tag ✅ shown');
      },
      onAdDismissedFullScreenContent: (a) {
        SafeLogger.d(_logTag, 'showAppOpen $tag 👋 dismissed');
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        _disposeAd(a, 'appOpen-after-dismiss');
        _appOpenAd = null;
        appOpenSlot.markDismissed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(true);
      },
      onAdFailedToShowFullScreenContent: (a, err) {
        SafeLogger.w(_logTag, 'showAppOpen $tag ❌ display failed: ${err.message}');
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        _disposeAd(a, 'appOpen-show-fail');
        _appOpenAd = null;
        appOpenSlot.markShowFailed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(false);
      },
      onAdClicked: (a) {
        SafeLogger.d(_logTag, 'showAppOpen $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
        ));
      },
      onAdImpression: (a) {},
    );
    try {
      await ad.show();
      // Safety net: if neither dismiss nor fail callback fires (rare GMA /
      // mediation hang), force-dismiss after the hard cap so the caller — which
      // on the resume path has no other recovery timer — never hangs.
      _armAppOpenWatchdog(onDismiss);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showAppOpen $tag show THREW: $e\n$st');
      _appOpenShowTimeout?.cancel();
      _appOpenShowTimeout = null;
      _appOpenAd = null;
      appOpenSlot.markShowFailed();
      final cb = _appOpenDismiss;
      _appOpenDismiss = null;
      cb?.call(false);
    }
  }

  /// Arms the App Open show watchdog. Captures [captured] (the *local*
  /// onDismiss) and verifies identity before firing, so a watchdog left over
  /// from a previous show can never resolve a newer show's callback. [cap] is
  /// overridable for tests.
  void _armAppOpenWatchdog(void Function(bool) captured, {Duration? cap}) {
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = Timer(cap ?? _appOpenShowHardCap, () {
      _appOpenShowTimeout = null;
      // Only fire if THIS show's callback is still the pending one.
      if (_appOpenDismiss != captured) return; // already resolved / replaced
      SafeLogger.w(_logTag,
          'showAppOpen $tag ⏰ HARD CAP — no dismiss callback, force dismiss(false)');
      _appOpenAd = null;
      appOpenSlot.markShowFailed();
      _appOpenDismiss = null;
      captured(false);
    });
  }

  /// Test seam: simulate an App Open that is "showing" then arm the watchdog
  /// with a short [cap] so the hard-cap path can be exercised without the
  /// native GMA `AppOpenAd`.
  @visibleForTesting
  void debugSimulateAppOpenShowAndArmWatchdog(
      void Function(bool) onDismiss, Duration cap) {
    appOpenSlot.beginLoad();
    appOpenSlot.markReady();
    appOpenSlot.beginShow();
    _appOpenDismiss = onDismiss;
    _armAppOpenWatchdog(onDismiss, cap: cap);
  }

  @visibleForTesting
  bool get debugWatchdogArmed => _appOpenShowTimeout != null;

  // ──────────────────────────────────────────────────────────────────────────
  //  INTERSTITIAL
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> loadInterstitial() async {
    final cfg = _admob;
    if (cfg == null) return;
    // Reuse only if still fresh (≤1h); a stale cached ad fails on show().
    if (_interstitialAd != null) {
      if (isAdFresh(interstitialSlot.lastLoadedAt, _fullscreenExpiryHours)) {
        return; // fresh — keep it
      }
      SafeLogger.d(_logTag, 'loadInterstitial $tag ♻️ expired (>${_fullscreenExpiryHours}h), disposing old');
      _disposeAd(_interstitialAd, 'inter-expired');
      _interstitialAd = null;
      interstitialSlot.lastLoadedAt = null;
    }
    if (!interstitialSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadInterstitial $tag 🔄');
    try {
      await InterstitialAd.load(
        adUnitId: cfg.interstitialId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            SafeLogger.d(_logTag, 'loadInterstitial $tag ✅');
            _interstitialAd = ad;
            _wirePaidEvent(ad, AdSlotType.interstitial, AdPlacement.unspecified);
            interstitialSlot.markReady();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.interstitial,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (err) {
            SafeLogger.w(_logTag, 'loadInterstitial $tag ❌ ${err.code}');
            _interstitialAd = null;
            interstitialSlot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.interstitial,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
        ),
      );
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadInterstitial $tag THREW: $e\n$st');
      _interstitialAd = null;
      interstitialSlot.markFailed();
    }
  }

  @override
  Future<void> showInterstitial({required void Function(bool shown) onDone}) async {
    final ad = _interstitialAd;
    if (ad == null || !interstitialSlot.isReady) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ not ready');
      onDone(false);
      return;
    }
    if (!interstitialSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ already showing');
      onDone(false);
      return;
    }
    _interstitialDone = onDone;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (a) => SafeLogger.d(_logTag, 'showInterstitial $tag ✅ shown'),
      onAdDismissedFullScreenContent: (a) {
        SafeLogger.d(_logTag, 'showInterstitial $tag 👋 dismissed');
        _disposeAd(a, 'inter-after-dismiss');
        _interstitialAd = null;
        interstitialSlot.markDismissed();
        final cb = _interstitialDone;
        _interstitialDone = null;
        cb?.call(true);
      },
      onAdFailedToShowFullScreenContent: (a, err) {
        SafeLogger.w(_logTag, 'showInterstitial $tag ❌ display failed: ${err.message}');
        _disposeAd(a, 'inter-show-fail');
        _interstitialAd = null;
        interstitialSlot.markShowFailed();
        final cb = _interstitialDone;
        _interstitialDone = null;
        cb?.call(false);
      },
      onAdClicked: (a) {
        SafeLogger.d(_logTag, 'showInterstitial $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
        ));
      },
    );
    try {
      await ad.show();
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showInterstitial $tag THREW: $e\n$st');
      _interstitialAd = null;
      interstitialSlot.markShowFailed();
      final cb = _interstitialDone;
      _interstitialDone = null;
      cb?.call(false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  REWARDED
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> loadRewarded() async {
    final cfg = _admob;
    if (cfg == null) return;
    // Reuse only if still fresh (≤1h); a stale cached ad fails on show().
    if (_rewardedAd != null) {
      if (isAdFresh(rewardedSlot.lastLoadedAt, _fullscreenExpiryHours)) {
        return; // fresh — keep it
      }
      SafeLogger.d(_logTag, 'loadRewarded $tag ♻️ expired (>${_fullscreenExpiryHours}h), disposing old');
      _disposeAd(_rewardedAd, 'rewarded-expired');
      _rewardedAd = null;
      rewardedSlot.lastLoadedAt = null;
    }
    if (!rewardedSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadRewarded $tag 🔄');
    try {
      await RewardedAd.load(
        adUnitId: cfg.rewardedId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            SafeLogger.d(_logTag, 'loadRewarded $tag ✅');
            _rewardedAd = ad;
            _wirePaidEvent(ad, AdSlotType.rewarded, AdPlacement.unspecified);
            rewardedSlot.markReady();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.rewarded,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (err) {
            SafeLogger.w(_logTag, 'loadRewarded $tag ❌ ${err.code}');
            _rewardedAd = null;
            rewardedSlot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.rewarded,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
        ),
      );
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadRewarded $tag THREW: $e\n$st');
      _rewardedAd = null;
      rewardedSlot.markFailed();
    }
  }

  @override
  Future<void> showRewarded({required void Function(RewardResult result) onDone}) async {
    final ad = _rewardedAd;
    if (ad == null || !rewardedSlot.isReady) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ not ready');
      onDone(RewardResult.skipped);
      return;
    }
    if (!rewardedSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ already showing');
      onDone(RewardResult.skipped);
      return;
    }
    _rewardedDone = onDone;

    // Local guards against double-fire (Fix #42 preserved).
    var earned = false;
    var fired = false;
    void fire(RewardResult r) {
      if (fired) return;
      fired = true;
      final cb = _rewardedDone;
      _rewardedDone = null;
      cb?.call(r);
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (a) => SafeLogger.d(_logTag, 'showRewarded $tag ✅ shown'),
      onAdDismissedFullScreenContent: (a) {
        SafeLogger.d(_logTag, 'showRewarded $tag 👋 dismissed (earned=$earned)');
        _disposeAd(a, 'rewarded-after-dismiss');
        _rewardedAd = null;
        rewardedSlot.markDismissed();
        if (!earned) fire(RewardResult.skipped);
      },
      onAdFailedToShowFullScreenContent: (a, err) {
        SafeLogger.w(_logTag, 'showRewarded $tag ❌ display failed: ${err.message}');
        _disposeAd(a, 'rewarded-show-fail');
        _rewardedAd = null;
        rewardedSlot.markShowFailed();
        fire(RewardResult.skipped);
      },
      onAdClicked: (a) {
        SafeLogger.d(_logTag, 'showRewarded $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
        ));
      },
    );

    try {
      await ad.show(onUserEarnedReward: (a, reward) {
        SafeLogger.d(_logTag, 'showRewarded $tag 🏆 type=${reward.type} amount=${reward.amount}');
        earned = true;
        fire(RewardResult(earned: true, label: reward.type, amount: reward.amount));
      });
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showRewarded $tag show THREW: $e\n$st');
      _rewardedAd = null;
      rewardedSlot.markShowFailed();
      fire(RewardResult.skipped);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  BANNER
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> preloadBanner() async {
    // AdMob banner loads on widget mount when width is known — no preload here.
    SafeLogger.d(_logTag, 'preloadBanner $tag (no-op for AdMob)');
  }

  @override
  Future<void> loadBannerIfNeeded(double widthPx) async {
    final cfg = _admob;
    if (cfg == null) return;
    if (_bannerAd != null) {
      SafeLogger.d(_logTag, 'loadBanner $tag ⏭️ already cached');
      return;
    }
    // Transition the slot to `loading` BEFORE creating the BannerAd. GMA's
    // onAdLoaded/onAdFailedToLoad can fire synchronously on a cached fill — if
    // beginLoad() ran AFTER ..load() it would overwrite the ready/cooldown
    // state the callback set and strand the slot in `loading` forever.
    // Use beginLoad (not beginReload) so a flapping banner still respects the
    // backoff window — banner reload is cheap to skip, unlike a spent fullscreen.
    if (!bannerSlot.beginLoad()) {
      SafeLogger.d(_logTag, 'loadBanner $tag ⏭️ already loading/showing or in cooldown');
      return;
    }
    banner.isLoaded.value = false;
    SafeLogger.d(_logTag, 'loadBanner $tag 🔄 width=$widthPx');
    try {
      final adaptive = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(widthPx.truncate());
      final size = adaptive ?? AdSize.banner;
      _bannerAd = BannerAd(
        adUnitId: cfg.bannerId,
        size: size,
        request: const AdRequest(),
        listener: BannerAdListener(
          onPaidEvent: _paidEventForBanner(AdPlacement.unspecified),
          onAdLoaded: (ad) {
            SafeLogger.d(_logTag, 'loadBanner $tag ✅');
            banner.isLoaded.value = true;
            banner.hasError.value = false;
            banner.adSize.value = Size(size.width.toDouble(), size.height.toDouble());
            bannerSlot.markReady();
            // Counts towards CTR denominator (preserves original 1.x Fix J).
            AdSafetyConfig.recordBannerImpression();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (ad, err) {
            SafeLogger.w(_logTag, 'loadBanner $tag ❌ ${err.code}');
            try {
              ad.dispose();
            } catch (_) {}
            _bannerAd = null;
            banner.isLoaded.value = false;
            banner.hasError.value = true;
            bannerSlot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
          onAdOpened: (ad) {
            SafeLogger.d(_logTag, 'banner $tag 🎯 click');
            AdSafetyConfig.recordAdClick();
            _emit(AdClickEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
            ));
          },
          onAdClosed: (ad) => SafeLogger.d(_logTag, 'banner $tag closed'),
        ),
      )..load();
      // Slot already transitioned to `loading` above (before BannerAd creation).
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadBanner $tag adaptive size THREW: $e\n$st');
      banner.hasError.value = true;
      bannerSlot.markFailed();
    }
  }

  @override
  Widget? buildAdmobBannerView() {
    final ad = _bannerAd;
    if (ad == null) return null;
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE HOOKS
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void onAppPaused() {
    if (_bannerAd != null) {
      banner.visible.value = false;
    }
  }

  @override
  void onAppResumed() {
    // Reload banner if it errored out (Fix #14 preserved).
    if (banner.hasError.value && _bannerAd == null) {
      banner.hasError.value = false;
      // Width is unknown here — caller (AdManager) supplies it via
      // platformDispatcher when it forwards the resume.
      // Prefer the app's implicit (primary) view — `views.first` can be the
      // wrong window on foldables / iPad split-view / multi-window.
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      final view = dispatcher.implicitView ??
          (dispatcher.views.isNotEmpty ? dispatcher.views.first : null);
      if (view != null) {
        final width = view.physicalSize.width / view.devicePixelRatio;
        loadBannerIfNeeded(width);
      } else {
        SafeLogger.w(_logTag, 'onAppResumed $tag no platform view — skip reload');
      }
    } else if (_bannerAd != null) {
      banner.visible.value = true;
    }
  }
}
