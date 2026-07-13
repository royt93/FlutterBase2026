import 'dart:async';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/ad_config.dart';
import '../core/ad_consent.dart';
import '../core/ad_provider_adapter.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'applovin_bridge.dart';

/// AppLovin MAX implementation of [AdProviderAdapter].
class AppLovinAdapter implements AdProviderAdapter {
  /// [bridge] defaults to the real `AppLovinMAX` plugin; tests inject a fake.
  /// [lifecycleStateResolver] defaults to the real app lifecycle state; the App
  /// Open watchdog reads it through this seam so tests can drive the
  /// foreground/background branches deterministically.
  AppLovinAdapter({
    AppLovinBridge bridge = const RealAppLovinBridge(),
    AppLifecycleState? Function()? lifecycleStateResolver,
  })  : _bridge = bridge,
        _lifecycleState = lifecycleStateResolver ??
            (() => WidgetsBinding.instance.lifecycleState);

  final AppLovinBridge _bridge;
  final AppLifecycleState? Function() _lifecycleState;

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

  final ValueNotifier<AdViewId?> _bannerAdViewId =
      ValueNotifier<AdViewId?>(null);

  @override
  ValueListenable<Object?> get appLovinBannerAdViewId => _bannerAdViewId;

  @override
  String? get appLovinBannerId => _max?.bannerId;

  void Function(bool dismissed)? _appOpenDismiss;
  void Function(bool loaded)? _appOpenLoadCb;
  void Function(bool shown)? _interstitialDone;
  void Function(RewardResult result)? _rewardedDone;

  /// Set true in [showRewarded] when the caller supplied SSV identifying
  /// data for the in-flight show — read once by the reward callback to stamp
  /// [RewardResult.pendingServerConfirmation].
  bool _pendingSsv = false;

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
    // T01 — when Google UMP is the consent source, disable AppLovin's own CMP
    // flow so the user isn't prompted twice. Must be set BEFORE SDK init.
    if (config.disableAppLovinCmpFlow) {
      try {
        _bridge.setTermsAndPrivacyPolicyFlowEnabled(false);
        SafeLogger.d(_logTag, 'AppLovin CMP flow disabled (UMP is CMP)');
      } catch (e) {
        SafeLogger.w(_logTag, 'setTermsAndPrivacyPolicyFlowEnabled failed: $e');
      }
    }
    try {
      await _bridge.initialize(cfg.sdkKey);
      SafeLogger.d(_logTag, 'initialize $tag ✅ SDK ready');

      // Register THIS device as a test device in debug builds — required
      // by AppLovin to avoid serving real (revenue-counting) ads to the
      // developer. Failing to do so risks account suspension. Preserves
      // 1.x behaviour exactly.
      if (kDebugMode && deviceGaid.isNotEmpty) {
        try {
          _bridge.setTestDeviceAdvertisingIds([deviceGaid]);
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
      _bridge.setAppOpenAdListener(null);
      _bridge.setInterstitialListener(null);
      _bridge.setRewardedAdListener(null);
      _bridge.setWidgetAdViewAdListener(null);
    } catch (e) {
      SafeLogger.w(_logTag, 'dispose() listener clear threw: $e');
    }

    // Now destroy the native widget AdView. Without this the native side
    // keeps the previous banner alive across destroy → re-init cycles.
    final oldId = _bannerAdViewId.value;
    if (oldId != null) {
      try {
        await _bridge.destroyWidgetAdView(oldId);
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

    // This adapter instance is discarded after dispose() — a fresh one is
    // constructed on the next initialize() — so it's safe to permanently
    // dispose the ValueNotifiers here rather than just resetting their value.
    appOpenSlot.dispose();
    interstitialSlot.dispose();
    rewardedSlot.dispose();
    bannerSlot.dispose();
    banner.dispose();
    _bannerAdViewId.dispose();

    _max = null;
    _config = null;
  }

  @override
  void applyConsent(AdConsent consent) {
    // No-op: AppLovin consent is forwarded via the static `AppLovinMAX`
    // privacy APIs in `applyConsentToProviders` (setHasUserConsent /
    // setDoNotSell). AppLovin has no per-request non-personalized flag, so
    // there is nothing to store on the adapter.
  }

  // ─── App Open ─────────────────────────────────────────────────────────────

  void _wireAppOpenListener(String unitId) {
    _bridge.setAppOpenAdListener(AppOpenAdListener(
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
      onAdDisplayedCallback: (ad) =>
          SafeLogger.d(_logTag, 'appOpen $tag ✅ displayed'),
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(ad, AdSlotType.appOpen, AdPlacement.splash);
      },
      onAdDisplayFailedCallback: (ad, err) {
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        // Late arrival (see onAdHiddenCallback above) — watchdog already
        // resolved this show cycle; don't clobber state or double-reload.
        if (_appOpenDismiss == null) {
          SafeLogger.w(_logTag,
              'appOpen $tag ❌ display failed (late — watchdog already handled this show): ${err.message}');
          return;
        }
        SafeLogger.w(_logTag, 'appOpen $tag ❌ display failed: ${err.message}');
        appOpenSlot.markShowFailed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(false);
        // beginReload (not beginLoad) — the show failed but the load path is
        // healthy, so refill immediately instead of waiting out the backoff
        // window the show-failure just armed.
        if (appOpenSlot.beginReload()) {
          try {
            _bridge.loadAppOpenAd(unitId);
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
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        // Late arrival: the smart-timeout watchdog already force-dismissed
        // this show cycle (_appOpenDismiss cleared, slot moved out of
        // `showing`) before AppLovin's native callback landed — see the
        // "unreliable, sometimes fires LATE" comment in [showAppOpen]. Acting
        // again here would clobber whatever state the reload-in-flight has
        // already moved to and fire a SECOND raw `_bridge.loadAppOpenAd`
        // call that bypasses AdManager's VIP/consent/daily-cap gates.
        if (_appOpenDismiss == null) {
          SafeLogger.d(_logTag,
              'appOpen $tag 👋 hidden (late — watchdog already handled this show)');
          return;
        }
        SafeLogger.d(_logTag, 'appOpen $tag 👋 hidden');
        appOpenSlot.markDismissed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(true);
        if (appOpenSlot.beginLoad()) {
          try {
            _bridge.loadAppOpenAd(unitId);
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
      _bridge.loadAppOpenAd(cfg.appOpenId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadAppOpen $tag THREW: $e\n$st');
      appOpenSlot.markFailed();
    }
  }

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
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

    SafeLogger.d(_logTag, 'showAppOpen $tag → _bridge.showAppOpenAd');
    try {
      _bridge.showAppOpenAd(cfg.appOpenId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showAppOpen $tag THREW: $e\n$st');
      appOpenSlot.markShowFailed();
      final cb = _appOpenDismiss;
      _appOpenDismiss = null;
      cb?.call(false);
      return;
    }

    // Smart timeout: AppLovin's `onAdHiddenCallback` is unreliable — sometimes
    // fires LATE (10-30s after dismiss), especially when the user clicks the
    // ad and is sent to a browser/app store before returning.
    //
    // Strategy depends on platform, because the app lifecycle behaves
    // differently while a full-screen App Open ad is on screen:
    //   - ANDROID: the ad launches a separate Activity → Flutter goes
    //     `paused`/`inactive`. So `resumed` (foreground) WITHOUT a hidden
    //     callback genuinely means a hung overlay → force-dismiss after a
    //     short grace.
    //   - iOS: the ad is presented as a modal view controller WITHIN the app
    //     → Flutter stays `resumed` the whole time the ad shows. Foreground is
    //     therefore NOT a hung-ad signal; treating it as one (the old logic)
    //     force-dismissed every iOS App Open at ~10 s while it was displaying
    //     fine. On iOS we only rely on the native hidden/displayFailed
    //     callbacks plus the 90 s hard cap.
    //
    // An old fixed 10 s timeout also fired false-positive in QA (user click →
    // browser → 20+s → return), arming dismiss timestamps prematurely and
    // letting subsequent app-open trigger leak through the resume guard.
    _appOpenShowTimeout?.cancel();
    final captured = onDismiss;
    _scheduleAppOpenTimeoutCheck(captured, attempt: 0);
  }

  /// Test seam: put the App Open slot into `showing` and arm the watchdog with
  /// [captured] as the pending dismiss callback, so the lifecycle/platform
  /// branches of [_scheduleAppOpenTimeoutCheck] can be driven under `FakeAsync`.
  @visibleForTesting
  void debugStartAppOpenWatchdog(void Function(bool) captured) {
    appOpenSlot.beginLoad();
    appOpenSlot.markReady();
    appOpenSlot.beginShow();
    _appOpenDismiss = captured;
    _scheduleAppOpenTimeoutCheck(captured, attempt: 0);
  }

  /// Recursive lifecycle-aware timeout. On Android, force-dismisses shortly
  /// after observing the app foreground without a hidden callback (= hung
  /// overlay). On iOS the ad shows while the app stays `resumed`, so foreground
  /// is ignored and only the hard cap of 18 attempts × 5 s = 90 s applies.
  void _scheduleAppOpenTimeoutCheck(
    void Function(bool) captured, {
    required int attempt,
  }) {
    const tickSeconds = 5;
    const maxAttempts = 18; // 18 × 5 s = 90 s hard cap
    // iOS presents the App Open ad as an in-app modal VC, so Flutter never
    // leaves `resumed` while it shows — the foreground-as-hung heuristic only
    // holds on Android. See the comment block in [showAppOpen].
    final foregroundMeansHung = defaultTargetPlatform != TargetPlatform.iOS;
    _appOpenShowTimeout = Timer(const Duration(seconds: tickSeconds), () {
      _appOpenShowTimeout = null;
      // Already dismissed by AppLovin's normal callback path? Nothing to do.
      if (_appOpenDismiss != captured || !appOpenSlot.isShowing) {
        SafeLogger.d(_logTag,
            'showAppOpen $tag ⏰ tick #$attempt — already dismissed via callback, watcher exits');
        return;
      }
      final lifecycle = _lifecycleState();
      final isForeground = lifecycle == AppLifecycleState.resumed;

      if (isForeground && foregroundMeansHung) {
        // Android: app foreground but ad hasn't fired hidden. Could be:
        //   (a) Hung overlay — needs force-dismiss
        //   (b) Just-resumed transition — AppLovin's hidden callback is
        //       still in-flight via method channel (typically lands within
        //       ~500-1000 ms of the activity transition).
        //
        // Treat the FIRST foreground tick as a grace period — re-arm one
        // more tick to give AppLovin's natural callback time to land.
        // Only force-dismiss if app is STILL foreground on the second
        // foreground-observed tick.
        if (attempt < 1) {
          SafeLogger.d(_logTag,
              'showAppOpen $tag ⏰ tick #${attempt + 1} foreground but no callback yet — grace period, re-arming');
          _scheduleAppOpenTimeoutCheck(captured, attempt: attempt + 1);
          return;
        }
        SafeLogger.e(_logTag,
            'showAppOpen $tag ⏰ TIMEOUT — app foreground for ${(attempt + 1) * tickSeconds}s without hidden callback, force dismiss(false)');
        appOpenSlot.markShowFailed();
        _appOpenDismiss = null;
        captured(false);
        return;
      }
      // iOS foreground (ad shows while resumed), or Android backgrounded (ad on
      // screen / user in browser via click): the ad is presumed still up. Keep
      // waiting for the native hidden callback until the 90 s hard cap.
      if (attempt >= maxAttempts) {
        SafeLogger.e(_logTag,
            'showAppOpen $tag ⏰ HARD CAP ${maxAttempts * tickSeconds}s reached (lifecycle=${lifecycle?.name}) — force dismiss(false)');
        appOpenSlot.markShowFailed();
        _appOpenDismiss = null;
        captured(false);
        return;
      }
      SafeLogger.d(_logTag,
          'showAppOpen $tag ⏰ tick #${attempt + 1}/$maxAttempts (lifecycle=${lifecycle?.name}, fgHung=$foregroundMeansHung) — re-arming +${tickSeconds}s');
      _scheduleAppOpenTimeoutCheck(captured, attempt: attempt + 1);
    });
  }

  // ─── Interstitial ─────────────────────────────────────────────────────────

  void _wireInterstitialListener(String unitId) {
    _bridge.setInterstitialListener(InterstitialListener(
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
      onAdDisplayedCallback: (ad) {
        SafeLogger.d(
            _logTag,
            () => 'inter $tag ✅ displayed | network=${ad.networkName} '
                'creativeId=${ad.creativeId} placement=${ad.placement} '
                'latency=${ad.latencyMillis}ms');
      },
      onAdRevenuePaidCallback: (ad) {
        SafeLogger.d(
            _logTag,
            () => 'inter $tag 💰 revenue=\$${ad.revenue} '
                'precision=${ad.revenuePrecision} network=${ad.networkName}');
        _emitRevenueIfPresent(
            ad, AdSlotType.interstitial, AdPlacement.unspecified);
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.w(
            _logTag,
            () =>
                'inter $tag ❌ display failed: code=${err.code} message="${err.message}"');
        interstitialSlot.markShowFailed();
        final cb = _interstitialDone;
        _interstitialDone = null;
        cb?.call(false);
        // beginReload — refill past the show-failure backoff window.
        if (interstitialSlot.beginReload()) {
          try {
            _bridge.loadInterstitial(unitId);
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
            _bridge.loadInterstitial(unitId);
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
      _bridge.loadInterstitial(cfg.interstitialId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadInterstitial $tag THREW: $e\n$st');
      interstitialSlot.markFailed();
    }
  }

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
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
    SafeLogger.d(_logTag,
        'showInterstitial $tag → _bridge.showInterstitial(${cfg.interstitialId})');
    try {
      _bridge.showInterstitial(cfg.interstitialId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showInterstitial $tag THREW: $e\n$st');
      interstitialSlot.markShowFailed();
      final cb = _interstitialDone;
      _interstitialDone = null;
      cb?.call(false);
    }
  }

  /// Test seam: put the interstitial slot into `showing` with [onDone]
  /// captured, then immediately simulate AppLovin's `onAdHiddenCallback` (or
  /// `onAdDisplayFailedCallback` when [dismissed] is `false`) — the same
  /// callback path `_wireInterstitialListener` drives in production. Unlike
  /// App Open, there is no watchdog/timer here: AppLovin's fullscreen
  /// interstitial callbacks are treated as reliable, so this hook only
  /// exercises the plain `beginShow()` → `markDismissed()`/`markShowFailed()`
  /// transition — the exact path a zombie-`showing` bug would corrupt.
  @visibleForTesting
  void debugSimulateInterstitialShowAndDismiss(
    void Function(bool) onDone, {
    bool dismissed = true,
  }) {
    interstitialSlot.beginLoad();
    interstitialSlot.markReady();
    interstitialSlot.beginShow();
    _interstitialDone = onDone;
    final cb = _interstitialDone;
    _interstitialDone = null;
    if (dismissed) {
      interstitialSlot.markDismissed();
      cb?.call(true);
    } else {
      interstitialSlot.markShowFailed();
      cb?.call(false);
    }
  }

  // ─── Rewarded ─────────────────────────────────────────────────────────────

  void _wireRewardedListener(String unitId) {
    _bridge.setRewardedAdListener(RewardedAdListener(
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
      onAdDisplayedCallback: (ad) =>
          SafeLogger.d(_logTag, 'rewarded $tag ✅ displayed'),
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(ad, AdSlotType.rewarded, AdPlacement.unspecified);
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.w(_logTag, 'rewarded $tag ❌ display failed: ${err.message}');
        rewardedSlot.markShowFailed();
        final cb = _rewardedDone;
        _rewardedDone = null;
        cb?.call(RewardResult.skipped);
        // beginReload — refill past the show-failure backoff window.
        if (rewardedSlot.beginReload()) {
          try {
            _bridge.loadRewardedAd(unitId);
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
            _bridge.loadRewardedAd(unitId);
          } catch (e) {
            SafeLogger.e(_logTag, 'reload rewarded threw: $e');
            rewardedSlot.markFailed();
          }
        }
      },
      onAdReceivedRewardCallback: (ad, reward) {
        // Note: AppLovin **test creatives** report `amount=0` and empty
        // `label` regardless of what the dashboard rewarded ad-unit declares.
        // Real rewarded creatives in production return the configured values.
        // The `earned=true` flag is the source of truth for "user finished
        // watching" — `amount` is purely informational metadata.
        SafeLogger.d(
          _logTag,
          () =>
              'rewarded $tag 🏆 label="${reward.label}" amount=${reward.amount} '
              '(test creatives report 0/empty — earned=true is the truth)',
        );
        final cb = _rewardedDone;
        _rewardedDone = null;
        final pendingSsv = _pendingSsv;
        _pendingSsv = false;
        cb?.call(RewardResult(
          earned: true,
          label: reward.label,
          amount: reward.amount,
          pendingServerConfirmation: pendingSsv,
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
      _bridge.loadRewardedAd(cfg.rewardedId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadRewarded $tag THREW: $e\n$st');
      rewardedSlot.markFailed();
    }
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
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
    // AppLovin's SSV surface is a single `custom_data` string (no separate
    // userId field) — pass ssvCustomData verbatim, or fall back to ssvUserId
    // so a caller that only has a userId still gets it into the postback.
    final customData = ssvCustomData ?? ssvUserId;
    _pendingSsv = customData != null;
    SafeLogger.d(_logTag,
        'showRewarded $tag → _bridge.showRewardedAd(${cfg.rewardedId})');
    try {
      _bridge.showRewardedAd(cfg.rewardedId, customData: customData);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showRewarded $tag THREW: $e\n$st');
      rewardedSlot.markShowFailed();
      final cb = _rewardedDone;
      _rewardedDone = null;
      cb?.call(RewardResult.skipped);
    }
  }

  /// Test seam: put the rewarded slot into `showing` with [onDone] captured,
  /// then immediately simulate AppLovin's `onAdHiddenCallback` (or
  /// `onAdDisplayFailedCallback` when [dismissed] is `false`) — mirrors
  /// [debugSimulateInterstitialShowAndDismiss]. No watchdog exists for
  /// rewarded either, so this only exercises the plain `beginShow()` →
  /// `markDismissed()`/`markShowFailed()` transition.
  @visibleForTesting
  void debugSimulateRewardedShowAndDismiss(
    void Function(RewardResult) onDone, {
    bool dismissed = true,
  }) {
    rewardedSlot.beginLoad();
    rewardedSlot.markReady();
    rewardedSlot.beginShow();
    _rewardedDone = onDone;
    final cb = _rewardedDone;
    _rewardedDone = null;
    if (dismissed) {
      rewardedSlot.markDismissed();
      cb?.call(RewardResult.skipped);
    } else {
      rewardedSlot.markShowFailed();
      cb?.call(RewardResult.skipped);
    }
  }

  // ─── Banner ──────────────────────────────────────────────────────────────

  @override
  Future<void> preloadBanner() async {
    final cfg = _max;
    if (cfg == null) return;
    SafeLogger.d(_logTag, 'preloadBanner $tag 🔄 id=${cfg.bannerId}');

    _bridge.setWidgetAdViewAdListener(WidgetAdViewAdListener(
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
      final adViewId = await _bridge.preloadWidgetAdView(
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
    // The diagnostic log reads several ValueNotifier values + our slot
    // states. If the host activity is mid-recreation (AppLovin dismiss
    // path on Android can briefly leave Flutter widgets in a weird state),
    // any of these reads CAN theoretically throw — wrap in try-catch so
    // the actual side-effect (disabling banner autoRefresh) always runs.
    try {
      SafeLogger.d(
        _logTag,
        () => 'onAppPaused $tag '
            '| banner.autoRefresh=${banner.autoRefreshEnabled.value} '
            '| bannerAdViewId=${_bannerAdViewId.value} '
            '| inter=${interstitialSlot.value.name} '
            '| rewarded=${rewardedSlot.value.name} '
            '| appOpen=${appOpenSlot.value.name} '
            '| pendingDismissCallback=${_appOpenDismiss != null}',
      );
    } catch (e) {
      SafeLogger.w(_logTag, 'onAppPaused diagnostic log threw: $e');
    }
    try {
      if (_bannerAdViewId.value != null) {
        banner.autoRefreshEnabled.value = false;
        SafeLogger.d(_logTag, 'onAppPaused $tag — banner.autoRefresh disabled');
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppPaused side-effect threw: $e\n$st');
    }
  }

  @override
  void onAppResumed() {
    try {
      SafeLogger.d(
        _logTag,
        () => 'onAppResumed $tag '
            '| banner.hasError=${banner.hasError.value} '
            '| banner.autoRefresh=${banner.autoRefreshEnabled.value} '
            '| bannerAdViewId=${_bannerAdViewId.value} '
            '| bannerRoutePaused=$_bannerRoutePaused '
            '| inter=${interstitialSlot.value.name} '
            '| rewarded=${rewardedSlot.value.name} '
            '| appOpen=${appOpenSlot.value.name}',
      );
    } catch (e) {
      SafeLogger.w(_logTag, 'onAppResumed diagnostic log threw: $e');
    }
    try {
      if (banner.hasError.value) {
        SafeLogger.d(
            _logTag, 'onAppResumed $tag — banner had error, recreating');
        final oldId = _bannerAdViewId.value;
        banner.hasError.value = false;
        _bannerAdViewId.value = null;
        banner.autoRefreshEnabled.value = true;
        if (oldId != null) {
          unawaited(_bridge.destroyWidgetAdView(oldId).catchError((e) {
            SafeLogger.w(
                _logTag, 'destroyWidgetAdView (onAppResumed) threw: $e');
          }));
        }
        preloadBanner();
      } else if (_bannerAdViewId.value != null && !_bannerRoutePaused) {
        banner.autoRefreshEnabled.value = true;
        SafeLogger.d(
            _logTag, 'onAppResumed $tag — banner.autoRefresh re-enabled');
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppResumed side-effect threw: $e\n$st');
    }
  }
}
