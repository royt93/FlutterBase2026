import 'package:connection_notifier/connection_notifier.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:advertising_id/advertising_id.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../config/ad_config.dart';
import '../utils/safe_logger.dart';
import '../utils/ad_preferences.dart';
import 'ad_safety_config.dart';
import 'event_bus.dart';

/// Dual-provider Ad Manager singleton.
///
/// Supports AdMob (google_mobile_ads) and AppLovin MAX (applovin_max).
/// Provider is selected via [AdConfig.provider] at initialize time.
///
/// Usage:
/// ```dart
/// await AdManager().initialize(
///   config: AdConfig(
///     provider: AdProvider.appLovin,
///     appLovin: AppLovinConfig(sdkKey: '...', bannerId: '...', ...),
///     vipDeviceGaids: ['gaid-owner-device'],
///   ),
///   onComplete: (success, gaid) {},
/// );
/// ```
class AdManager with WidgetsBindingObserver {
  static final AdManager _instance = AdManager._internal();
  factory AdManager() => _instance;

  AdManager._internal() {
    WidgetsBinding.instance.addObserver(this);
  }

  static const String _tag = 'AdManager';
  static const int _errorCooldown = 15 * 60 * 1000; // 15 min

  // ════════ CONFIG (set at initialize()) ════════
  late AdConfig _config;
  bool _initialized = false;

  /// Exposes the active config after [initialize] has been called.
  AdConfig? get config => _initialized ? _config : null;

  bool get _isAdmob => _config.isAdMob;
  String get _provider => _isAdmob ? '[AdMob]' : '[AppLovin]';

  // ════════ COMMON STATE ════════
  String _currentDeviceGAID = '';
  bool _isVipMember = false;
  bool _isSplashActive = true;
  int _countInitSplashScreen = 0;
  final Set<String> _setGAIDVipMember = {};

  // ════════ ADMOB STATE ════════
  AppOpenAd? _appOpenAd;
  InterstitialAd? _interstitialAd;
  bool _isInterLoading = false;
  bool _isInterstitialShowing = false;
  bool _isRewardedShowing = false;
  DateTime? _appOpenAdLoadTime;
  int _lastAppOpenErrorTime = 0;
  int _lastInterErrorTime = 0;
  bool _isAppOpenLoading = false;
  bool _isAppOpenShowing = false;

  // Banner spam guard
  int _lastBannerLoadTime = 0;
  static const int _bannerLoadCooldown = 5000;

  // ════════ APPLOVIN STATE ════════
  bool _isMaxInterReady = false;
  bool _isMaxAppOpenReady = false;
  bool _isMaxAppOpenShowing = false;
  void Function(bool)? _pendingInterDoneFlow;
  void Function(bool)? _onAppOpenDismissed;
  void Function(bool)? _pendingAppOpenLoadCallback;
  bool _isFirstAdLoadTriggered = false;
  bool _bannerRoutePaused = false;

  void setBannerRoutePaused(bool paused) => _bannerRoutePaused = paused;
  bool get bannerRoutePaused => _bannerRoutePaused;

  // ════════ UNIFIED BANNER STATE ════════
  final ValueNotifier<AdViewId?> bannerAdViewId = ValueNotifier(null);
  final ValueNotifier<bool> bannerAutoRefreshEnabled = ValueNotifier(true);
  final ValueNotifier<bool> bannerIsLoaded = ValueNotifier(false);
  final ValueNotifier<bool> bannerHasError = ValueNotifier(false);
  final ValueNotifier<Size?> bannerAdSize = ValueNotifier(null);
  final ValueNotifier<bool> bannerVisible = ValueNotifier(true);
  BannerAd? _admobBannerAd;

  // ════════ REWARDED STATE ════════
  RewardedAd? _rewardedAd;
  bool _isRewardedLoading = false;
  int _lastRewardedErrorTime = 0;
  bool _isMaxRewardedReady = false;
  void Function(bool)? _pendingRewardedDoneFlow;

  // ════════════════════════════════════════════════════
  // DEBUG HELPER
  // ════════════════════════════════════════════════════
  void _logAllAdStatus(String context) {
    final daily = AdSafetyConfig.getStatus();
    SafeLogger.d(
      _tag,
      '📊 [$context] AD STATUS SNAPSHOT:\n'
      '  ── AppOpen  ── ready=$_isMaxAppOpenReady | showing=$_isMaxAppOpenShowing | loading=$_isAppOpenLoading\n'
      '  ── Inter    ── ready=$_isMaxInterReady   | showing=$_isInterstitialShowing | loading=$_isInterLoading\n'
      '  ── Rewarded ── ready=$_isMaxRewardedReady | showing=$_isRewardedShowing | loading=$_isRewardedLoading\n'
      '  ── Banner   ── loaded=${bannerIsLoaded.value} | error=${bannerHasError.value} | autoRefresh=${bannerAutoRefreshEnabled.value} | adViewId=${bannerAdViewId.value}\n'
      '  ── Safety   ── $daily\n'
      '  ── VIP      ── isVIP=$_isVipMember | GAID=$_currentDeviceGAID',
    );
  }

  // ════════════════════════════════════════════════════
  // INIT
  // ════════════════════════════════════════════════════

  /// Initialize the ad SDK. Must be called before any ad methods.
  ///
  /// Call this in `main()` before `runApp()`:
  /// ```dart
  /// await AdManager().initialize(
  ///   config: AdConfig(provider: AdProvider.appLovin, appLovin: ...),
  ///   onComplete: (success, gaid) {},
  /// );
  /// ```
  Future<void> initialize({
    required AdConfig config,
    required void Function(bool success, String gaid) onComplete,
  }) async {
    _config = config;
    _initialized = true;
    SafeLogger.d(_tag, '###init called, provider=${config.provider}');

    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs);

    // Load VIP GAIDs from SharedPreferences
    _setGAIDVipMember.addAll(prefs.getGAIDList());
    SafeLogger.d(_tag, '###init setGAIDVipMember size: ${_setGAIDVipMember.length}');

    // Get device GAID
    try {
      final String? advertisingId = await AdvertisingId.id(true);
      _currentDeviceGAID = advertisingId ?? '';
      SafeLogger.d(_tag, '###init getGAID success: $_currentDeviceGAID');
    } on PlatformException catch (e) {
      SafeLogger.w(_tag, '###init getGAID PlatformException: $e');
    } catch (e) {
      SafeLogger.w(_tag, '###init getGAID Error: $e');
    }

    _isVipMember = _setGAIDVipMember.contains(_currentDeviceGAID);
    SafeLogger.d(_tag, '###init GAID: $_currentDeviceGAID, isVIP: $_isVipMember');

    // First init: add VIP GAIDs from config (release only)
    if (!prefs.isAddVIPMemberFirstInitSuccess()) {
      if (kDebugMode) {
        SafeLogger.d(_tag, '###init Debug mode, skip adding VIP members');
      } else {
        SafeLogger.d(_tag, '###init Release mode, adding VIP members for first time');
        addVIPMember(config.vipDeviceGaids);
        await prefs.addVIPMemberFirstInitSuccess();
      }
    }

    if (_isAdmob) {
      final admobConfig = config.admob!;
      await MobileAds.instance.initialize();
      final rc = RequestConfiguration(testDeviceIds: admobConfig.testDeviceIds);
      await MobileAds.instance.updateRequestConfiguration(rc);
      SafeLogger.d(_tag, '###init AdMob initialized');
    } else {
      final appLovinConfig = config.appLovin!;
      SafeLogger.d(_tag, '###init AppLovin mode, setting up listeners...');
      _setupAppLovinAppOpenListener();
      _setupAppLovinInterstitialListener();
      _setupAppLovinRewardedListener();

      await AppLovinMAX.initialize(appLovinConfig.sdkKey);
      SafeLogger.d(_tag, '###init AppLovin SDK initialized');

      if (kDebugMode && _currentDeviceGAID.isNotEmpty) {
        try {
          AppLovinMAX.setTestDeviceAdvertisingIds([_currentDeviceGAID]);
          SafeLogger.d(_tag, '###init AppLovin test device registered: $_currentDeviceGAID');
        } catch (e) {
          SafeLogger.d(_tag, '###init AppLovin test device registration failed: $e');
        }
      }
    }

    SafeLogger.d(_tag, '###init completed');
    onComplete(true, _currentDeviceGAID);
    _logAllAdStatus('after-init');
    SimpleEventBus().fire(const BoolEvent(true));

    SafeLogger.d(_tag, '###init triggering App Open Ad preload');
    loadAppOpenAd();

    if (!_isAdmob) {
      SafeLogger.d(_tag, '###init [AppLovin] preloading banner widget view...');
      _preloadAppLovinBanner();
    } else {
      SafeLogger.d(_tag, '###init [AdMob] banner will be loaded on BannerAdWidget mount');
    }
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw StateError(
        'AdManager not initialized. Call AdManager().initialize() before using any ad methods.',
      );
    }
  }

  // ════════════════════════════════════════════════════
  // BANNER — AppLovin preload
  // ════════════════════════════════════════════════════
  void _preloadAppLovinBanner() {
    _assertInitialized();
    final bannerId = _config.appLovin!.bannerId;
    if (_isVipMember) {
      SafeLogger.d(_tag, 'Banner [AppLovin] ⏭️ preload skipped — VIP device');
      bannerHasError.value = true;
      return;
    }
    SafeLogger.d(_tag, 'Banner [AppLovin] 🔄 preloadWidgetAdView() — id=$bannerId');

    AppLovinMAX.setWidgetAdViewAdListener(WidgetAdViewAdListener(
      onAdLoadedCallback: (ad) {
        final isInitialLoad = !bannerIsLoaded.value;
        if (isInitialLoad) {
          SafeLogger.d(
            _tag,
            '✅ [AppLovin] Banner preload loaded (initial), adViewId=${ad.adViewId}, '
            'network=${ad.networkName}, '
            'size=${ad.size?.width}x${ad.size?.height}',
          );
          bannerIsLoaded.value = true;
          bannerHasError.value = false;
        } else {
          SafeLogger.d(
            _tag,
            '♻️ [AppLovin] Banner auto-refreshed, adViewId=${ad.adViewId}',
          );
        }
        if (ad.size != null) {
          final newSize = Size(ad.size!.width.toDouble(), ad.size!.height.toDouble());
          if (bannerAdSize.value != newSize) {
            bannerAdSize.value = newSize;
          }
        }
      },
      onAdLoadFailedCallback: (adUnitId, err) {
        SafeLogger.d(_tag, '❌ [AppLovin] Banner preload failed: code=${err.code}, message=${err.message}');
        bannerIsLoaded.value = false;
        bannerHasError.value = true;
      },
    ));

    AppLovinMAX.preloadWidgetAdView(bannerId, AdFormat.banner).then((adViewId) {
      if (adViewId == null) {
        SafeLogger.d(_tag, '❌ [AppLovin] Banner preloadWidgetAdView returned null adViewId');
        bannerHasError.value = true;
        return;
      }
      SafeLogger.d(_tag, '✅ [AppLovin] Banner preload started, adViewId=$adViewId');
      bannerAdViewId.value = adViewId;
    }).catchError((e) {
      SafeLogger.d(_tag, '❌ [AppLovin] Banner preloadWidgetAdView error: $e');
      bannerHasError.value = true;
    });
  }

  /// [AdMob] Load banner ad on first BannerAdWidget mount.
  void loadAdmobBannerIfNeeded(double adWidth) {
    _assertInitialized();
    if (_isVipMember) {
      SafeLogger.d(_tag, 'Banner [AdMob] ⏭️ skipped — VIP device');
      bannerHasError.value = true;
      return;
    }
    if (!isConnected) {
      SafeLogger.d(_tag, 'Banner [AdMob] ⏭️ skipped — no internet');
      bannerHasError.value = true;
      return;
    }
    if (_admobBannerAd != null) {
      SafeLogger.d(_tag, 'Banner [AdMob] ⏭️ already cached, reusing');
      return;
    }
    final bannerId = _config.admob!.bannerId;
    SafeLogger.d(_tag, 'Banner [AdMob] 🔄 creating BannerAd, adWidth=$adWidth');

    AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(adWidth.truncate()).then((adaptiveSize) {
      final size = adaptiveSize ?? AdSize.banner;
      _admobBannerAd = BannerAd(
        adUnitId: bannerId,
        size: size,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (ad) {
            SafeLogger.d(_tag, '✅ [AdMob] Banner Ad Loaded');
            bannerIsLoaded.value = true;
            bannerHasError.value = false;
            bannerAdSize.value = Size(size.width.toDouble(), size.height.toDouble());
          },
          onAdFailedToLoad: (ad, error) {
            SafeLogger.d(_tag, '❌ [AdMob] Banner Failed: ${error.code}, ${error.message}');
            ad.dispose();
            _admobBannerAd = null;
            bannerIsLoaded.value = false;
            bannerHasError.value = true;
          },
          onAdOpened: (ad) {
            SafeLogger.d(_tag, '🎯 [AdMob] Banner Clicked/Opened');
            AdSafetyConfig.recordAdClick();
          },
          onAdClosed: (ad) => SafeLogger.d(_tag, '📝 [AdMob] Banner Closed'),
          onAdImpression: (ad) => SafeLogger.d(_tag, '👁️ [AdMob] Banner Impression'),
        ),
      )..load();
    }).catchError((e) {
      SafeLogger.d(_tag, '❌ [AdMob] Banner getAdaptiveSize error: $e');
      bannerHasError.value = true;
    });
  }

  BannerAd? get admobBannerAd => _admobBannerAd;

  // ════════════════════════════════════════════════════
  // APPLOVIN LISTENERS
  // ════════════════════════════════════════════════════
  void _setupAppLovinAppOpenListener() {
    final appOpenId = _config.appLovin!.appOpenId;
    AppLovinMAX.setAppOpenAdListener(AppOpenAdListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] App Open Ad Loaded');
        _isMaxAppOpenReady = true;
        _pendingAppOpenLoadCallback?.call(true);
        _pendingAppOpenLoadCallback = null;
        if (!_isFirstAdLoadTriggered) {
          _isFirstAdLoadTriggered = true;
          SafeLogger.d(_tag, '###loadOrder App Open loaded → loading Inter + Rewarded (first time)');
          loadInterstitial();
          loadRewardedAd();
        }
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.d(_tag, '❌ [AppLovin] App Open Ad Failed: code=${err.code}');
        _lastAppOpenErrorTime = DateTime.now().millisecondsSinceEpoch;
        _isMaxAppOpenReady = false;
        _pendingAppOpenLoadCallback?.call(false);
        _pendingAppOpenLoadCallback = null;
        if (!_isFirstAdLoadTriggered) {
          _isFirstAdLoadTriggered = true;
          SafeLogger.d(_tag, '###loadOrder App Open failed → fallback load Inter + Rewarded');
          loadInterstitial();
          loadRewardedAd();
        }
      },
      onAdDisplayedCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] App Open Ad Shown');
        AdSafetyConfig.recordFullscreenAdShown();
        _isMaxAppOpenShowing = true;
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.d(_tag, '❌ [AppLovin] App Open Display Failed: ${err.message}');
        _isMaxAppOpenShowing = false;
        _isMaxAppOpenReady = false;
        _onAppOpenDismissed?.call(true);
        _onAppOpenDismissed = null;
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_tag, '🎯 [AppLovin] App Open Ad Clicked');
        AdSafetyConfig.recordAdClick();
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] App Open Ad Dismissed — preloading next...');
        _isMaxAppOpenShowing = false;
        _isMaxAppOpenReady = false;
        _onAppOpenDismissed?.call(true);
        _onAppOpenDismissed = null;
        AppLovinMAX.loadAppOpenAd(appOpenId);
      },
    ));
  }

  void _setupAppLovinInterstitialListener() {
    final interId = _config.appLovin!.interstitialId;
    AppLovinMAX.setInterstitialListener(InterstitialListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] Interstitial Ad Loaded');
        _isMaxInterReady = true;
        _isInterLoading = false;
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.d(_tag, '❌ [AppLovin] Interstitial Ad Failed: code=${err.code}');
        _lastInterErrorTime = DateTime.now().millisecondsSinceEpoch;
        _isMaxInterReady = false;
        _isInterLoading = false;
        _pendingInterDoneFlow?.call(false);
        _pendingInterDoneFlow = null;
      },
      onAdDisplayedCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] Interstitial Ad Shown');
        AdSafetyConfig.recordFullscreenAdShown();
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.d(_tag, '❌ [AppLovin] Interstitial Display Failed: ${err.message}');
        _isInterstitialShowing = false;
        _pendingInterDoneFlow?.call(false);
        _pendingInterDoneFlow = null;
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_tag, '🎯 [AppLovin] Interstitial Ad Clicked');
        AdSafetyConfig.recordAdClick();
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] Interstitial Ad Dismissed — preloading next...');
        _isMaxInterReady = false;
        _isInterLoading = false;
        _isInterstitialShowing = false;
        _pendingInterDoneFlow?.call(true);
        _pendingInterDoneFlow = null;
        AppLovinMAX.loadInterstitial(interId);
      },
    ));
  }

  void _setupAppLovinRewardedListener() {
    final rewardedId = _config.appLovin!.rewardedId;
    AppLovinMAX.setRewardedAdListener(RewardedAdListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] Rewarded Ad Loaded');
        _isMaxRewardedReady = true;
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.d(_tag, '❌ [AppLovin] Rewarded Ad Failed: code=${err.code}');
        _lastRewardedErrorTime = DateTime.now().millisecondsSinceEpoch;
        _isMaxRewardedReady = false;
        _isRewardedLoading = false;
        _pendingRewardedDoneFlow?.call(false);
        _pendingRewardedDoneFlow = null;
      },
      onAdDisplayedCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] Rewarded Ad Shown');
        AdSafetyConfig.recordFullscreenAdShown();
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.d(_tag, '❌ [AppLovin] Rewarded Display Failed: ${err.message}');
        _isRewardedShowing = false;
        _pendingRewardedDoneFlow?.call(false);
        _pendingRewardedDoneFlow = null;
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_tag, '🎯 [AppLovin] Rewarded Ad Clicked');
        AdSafetyConfig.recordAdClick();
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_tag, '✅ [AppLovin] Rewarded Ad Dismissed — preloading next...');
        _isMaxRewardedReady = false;
        _isRewardedLoading = false;
        _isRewardedShowing = false;
        AppLovinMAX.loadRewardedAd(rewardedId);
      },
      onAdReceivedRewardCallback: (ad, reward) {
        SafeLogger.d(_tag, '🏆 [AppLovin] Rewarded Ad Earned Reward — type=${reward.label}, amount=${reward.amount}');
        _pendingRewardedDoneFlow?.call(true);
        _pendingRewardedDoneFlow = null;
      },
    ));
  }

  // ════════════════════════════════════════════════════
  // HELPERS
  // ════════════════════════════════════════════════════
  bool _isCooldown(int lastErrorTime) {
    if (lastErrorTime == 0) return false;
    return DateTime.now().millisecondsSinceEpoch - lastErrorTime < _errorCooldown;
  }

  bool get isConnected {
    try {
      return ConnectionNotifierTools.isConnected;
    } catch (_) {
      return true;
    }
  }

  // ════════════════════════════════════════════════════
  // APP OPEN AD — LOAD
  // ════════════════════════════════════════════════════
  void loadAppOpenAd({void Function(bool)? onAdLoaded}) {
    _assertInitialized();
    SafeLogger.d(_tag, 'loadAppOpenAd $_provider called, isVIP=$_isVipMember');
    if (_isVipMember) { onAdLoaded?.call(false); return; }
    if (!isConnected) { onAdLoaded?.call(false); return; }
    if (_isCooldown(_lastAppOpenErrorTime)) { onAdLoaded?.call(false); return; }

    if (_isAdmob) {
      _loadAppOpenAdAdmob(onAdLoaded: onAdLoaded);
    } else {
      _loadAppOpenAdAppLovin(onAdLoaded: onAdLoaded);
    }
  }

  void _loadAppOpenAdAdmob({void Function(bool)? onAdLoaded}) {
    if (_isAppOpenLoading) { onAdLoaded?.call(false); return; }
    if (_appOpenAd != null && _appOpenAdLoadTime != null) {
      if (DateTime.now().difference(_appOpenAdLoadTime!).inHours < 4) {
        onAdLoaded?.call(true); return;
      }
    }
    _isAppOpenLoading = true;
    final appOpenId = _config.admob!.appOpenId;
    AppOpenAd.load(
      adUnitId: appOpenId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          SafeLogger.d(_tag, 'loadAppOpenAd ✅ Ad Loaded');
          _appOpenAd = ad;
          _appOpenAdLoadTime = DateTime.now();
          _isAppOpenLoading = false;
          onAdLoaded?.call(true);
          if (!_isFirstAdLoadTriggered) {
            _isFirstAdLoadTriggered = true;
            loadInterstitial();
            loadRewardedAd();
          }
        },
        onAdFailedToLoad: (error) {
          SafeLogger.d(_tag, 'loadAppOpenAd ❌ Failed: ${error.code}');
          _lastAppOpenErrorTime = DateTime.now().millisecondsSinceEpoch;
          _isAppOpenLoading = false;
          onAdLoaded?.call(false);
          if (!_isFirstAdLoadTriggered) {
            _isFirstAdLoadTriggered = true;
            loadInterstitial();
            loadRewardedAd();
          }
        },
      ),
    );
  }

  void _loadAppOpenAdAppLovin({void Function(bool)? onAdLoaded}) {
    final appOpenId = _config.appLovin!.appOpenId;
    SafeLogger.d(_tag, 'loadAppOpenAd [AppLovin] 🔄 id=$appOpenId');
    _pendingAppOpenLoadCallback = onAdLoaded;
    AppLovinMAX.loadAppOpenAd(appOpenId);
  }

  // ════════════════════════════════════════════════════
  // APP OPEN AD — SHOW
  // ════════════════════════════════════════════════════
  void showAppOpenAd({
    required void Function(bool) onAdDismiss,
    bool bypassSafety = false,
  }) {
    _assertInitialized();
    SafeLogger.d(_tag, 'showAppOpenAd $_provider called, isVIP=$_isVipMember, bypassSafety=$bypassSafety');
    if (_isVipMember) { onAdDismiss(false); return; }

    final isShowing = _isAdmob ? _isAppOpenShowing : _isMaxAppOpenShowing;
    if (isShowing) { onAdDismiss(false); return; }

    if (!bypassSafety) {
      final safetyResult = AdSafetyConfig.canShowFullscreenAd();
      if (!safetyResult.canShow) {
        SafeLogger.d(_tag, 'showAppOpenAd $_provider 🛡️ blocked: ${safetyResult.reason}');
        onAdDismiss(false); return;
      }
    }

    if (_isAdmob) {
      _showAppOpenAdAdmob(onAdDismiss);
    } else {
      _showAppOpenAdAppLovin(onAdDismiss);
    }
  }

  void _showAppOpenAdAdmob(void Function(bool) onAdDismiss) {
    final ad = _appOpenAd;
    if (ad == null) { onAdDismiss(false); return; }
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        AdSafetyConfig.recordFullscreenAdShown();
        _isAppOpenShowing = true;
      },
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _appOpenAd = null;
        _isAppOpenShowing = false;
        onAdDismiss(true);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _appOpenAd = null;
        _isAppOpenShowing = false;
        onAdDismiss(true);
      },
      onAdClicked: (ad) => AdSafetyConfig.recordAdClick(),
      onAdImpression: (ad) {},
    );
    ad.show();
  }

  void _showAppOpenAdAppLovin(void Function(bool) onAdDismiss) {
    final appOpenId = _config.appLovin!.appOpenId;
    if (!_isMaxAppOpenReady) { onAdDismiss(false); return; }
    if (_isMaxAppOpenShowing) { onAdDismiss(false); return; }
    _onAppOpenDismissed = onAdDismiss;
    AppLovinMAX.showAppOpenAd(appOpenId);
  }

  // ════════════════════════════════════════════════════
  // APP OPEN ON RESUME
  // ════════════════════════════════════════════════════
  void showAppOpenAdOnResume() {
    SafeLogger.d(_tag, '▶️ showAppOpenAdOnResume $_provider triggered! isSplash=$_isSplashActive, isVIP=$_isVipMember');
    if (_isSplashActive || _isVipMember) return;
    if (_isInterstitialShowing || _isRewardedShowing) return;

    if (!AdSafetyConfig.canShowAppOpenOnResume()) {
      loadAppOpenAd();
      return;
    }

    final adReady = _isAdmob ? (_appOpenAd != null) : _isMaxAppOpenReady;
    final isShowing = _isAdmob ? _isAppOpenShowing : _isMaxAppOpenShowing;

    if (adReady && !isShowing) {
      showAppOpenAd(
        onAdDismiss: (wasActuallyShown) => loadAppOpenAd(),
        bypassSafety: false,
      );
    } else {
      loadAppOpenAd();
    }
  }

  // ════════════════════════════════════════════════════
  // LIFECYCLE OBSERVER
  // ════════════════════════════════════════════════════
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    SafeLogger.d(_tag, 'didChangeAppLifecycleState: state=$state');
    if (state == AppLifecycleState.paused) {
      SafeLogger.d(_tag, 'ProcessLifecycle ⏸️ App went to BACKGROUND');
      _logAllAdStatus('lifecycle-paused');
      AdSafetyConfig.recordAppWentBackground();

      if (!_isAdmob && bannerAdViewId.value != null) {
        bannerAutoRefreshEnabled.value = false;
      }
      if (_isAdmob && _admobBannerAd != null) {
        bannerVisible.value = false;
      }
    } else if (state == AppLifecycleState.resumed) {
      SafeLogger.d(_tag, 'ProcessLifecycle ▶️ App came to FOREGROUND');
      _logAllAdStatus('lifecycle-resumed');

      if (!_isAdmob) {
        if (bannerHasError.value) {
          bannerHasError.value = false;
          bannerAdViewId.value = null;
          bannerAutoRefreshEnabled.value = true; // reset BEFORE preload
          _preloadAppLovinBanner();
        } else if (bannerAdViewId.value != null && !_bannerRoutePaused) {
          bannerAutoRefreshEnabled.value = true;
        }
      }
      if (_isAdmob) {
        if (bannerHasError.value && _admobBannerAd == null) {
          bannerHasError.value = false;
        } else if (_admobBannerAd != null) {
          bannerVisible.value = true;
        }
      }

      showAppOpenAdOnResume();
    } else if (state == AppLifecycleState.inactive) {
      SafeLogger.d(_tag, 'ProcessLifecycle ⚠️ App is INACTIVE (transition state)');
    } else if (state == AppLifecycleState.detached) {
      SafeLogger.d(_tag, 'ProcessLifecycle 🚧 App is DETACHED');
    } else if (state == AppLifecycleState.hidden) {
      SafeLogger.d(_tag, 'ProcessLifecycle 👁️ App is HIDDEN');
    }
  }

  // ════════════════════════════════════════════════════
  // INTERSTITIAL — LOAD
  // ════════════════════════════════════════════════════
  void loadInterstitial() {
    _assertInitialized();
    SafeLogger.d(_tag, 'loadInterstitial $_provider called, isVIP=$_isVipMember');
    if (_isVipMember || !isConnected || _isCooldown(_lastInterErrorTime)) return;

    if (_isAdmob) {
      if (_interstitialAd != null || _isInterLoading) return;
      _isInterLoading = true;
      InterstitialAd.load(
        adUnitId: _config.admob!.interstitialId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) { _interstitialAd = ad; _isInterLoading = false; },
          onAdFailedToLoad: (error) {
            _lastInterErrorTime = DateTime.now().millisecondsSinceEpoch;
            _interstitialAd = null;
            _isInterLoading = false;
          },
        ),
      );
    } else {
      if (_isMaxInterReady || _isInterLoading) return;
      _isInterLoading = true;
      AppLovinMAX.loadInterstitial(_config.appLovin!.interstitialId);
    }
  }

  // ════════════════════════════════════════════════════
  // INTERSTITIAL — SHOW
  // ════════════════════════════════════════════════════
  void showInterstitial({required void Function(bool) onDoneFlow}) {
    _assertInitialized();
    SafeLogger.d(_tag, 'showInterstitial $_provider called, isVIP=$_isVipMember');
    if (_isVipMember) { onDoneFlow(false); return; }

    final safetyResult = AdSafetyConfig.canShowFullscreenAd();
    if (!safetyResult.canShow) { onDoneFlow(false); return; }

    if (_isAdmob) {
      _showInterstitialAdmob(onDoneFlow);
    } else {
      _showInterstitialAppLovin(onDoneFlow);
    }
  }

  void _showInterstitialAdmob(void Function(bool) onDoneFlow) {
    final ad = _interstitialAd;
    if (ad == null) { onDoneFlow(false); return; }
    _isInterstitialShowing = true;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (a) => AdSafetyConfig.recordFullscreenAdShown(),
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _interstitialAd = null;
        _isInterstitialShowing = false;
        loadInterstitial();
        onDoneFlow(true);
      },
      onAdFailedToShowFullScreenContent: (a, error) {
        a.dispose();
        _interstitialAd = null;
        _isInterstitialShowing = false;
        onDoneFlow(false);
      },
      onAdClicked: (a) => AdSafetyConfig.recordAdClick(),
    );
    ad.show();
  }

  void _showInterstitialAppLovin(void Function(bool) onDoneFlow) {
    if (!_isMaxInterReady) { onDoneFlow(false); return; }
    if (_isInterstitialShowing) { onDoneFlow(false); return; }
    _isMaxInterReady = false;
    _isInterstitialShowing = true;
    _pendingInterDoneFlow = onDoneFlow;
    AppLovinMAX.showInterstitial(_config.appLovin!.interstitialId);
  }

  // ════════════════════════════════════════════════════
  // REWARDED — LOAD
  // ════════════════════════════════════════════════════
  void loadRewardedAd() {
    _assertInitialized();
    SafeLogger.d(_tag, 'loadRewardedAd $_provider called, isVIP=$_isVipMember');
    if (_isVipMember || !isConnected || _isCooldown(_lastRewardedErrorTime)) return;

    if (_isAdmob) {
      if (_rewardedAd != null || _isRewardedLoading) return;
      _isRewardedLoading = true;
      RewardedAd.load(
        adUnitId: _config.admob!.rewardedId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) { _rewardedAd = ad; _isRewardedLoading = false; },
          onAdFailedToLoad: (error) {
            _lastRewardedErrorTime = DateTime.now().millisecondsSinceEpoch;
            _rewardedAd = null;
            _isRewardedLoading = false;
          },
        ),
      );
    } else {
      if (_isMaxRewardedReady || _isRewardedLoading) return;
      _isRewardedLoading = true;
      AppLovinMAX.loadRewardedAd(_config.appLovin!.rewardedId);
    }
  }

  // ════════════════════════════════════════════════════
  // REWARDED — SHOW
  // ════════════════════════════════════════════════════
  void showRewardedAd({required void Function(bool) onEarnedReward}) {
    _assertInitialized();
    SafeLogger.d(_tag, 'showRewardedAd $_provider called, isVIP=$_isVipMember');
    if (_isVipMember) { onEarnedReward(true); return; }

    final safetyResult = AdSafetyConfig.canShowFullscreenAd();
    if (!safetyResult.canShow) { onEarnedReward(false); return; }

    if (_isAdmob) {
      _showRewardedAdmob(onEarnedReward);
    } else {
      _showRewardedAppLovin(onEarnedReward);
    }
  }

  void _showRewardedAdmob(void Function(bool) onEarnedReward) {
    final ad = _rewardedAd;
    if (ad == null) { onEarnedReward(false); return; }
    bool hasEarned = false;
    _isRewardedShowing = true;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (a) => AdSafetyConfig.recordFullscreenAdShown(),
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _rewardedAd = null;
        _isRewardedShowing = false;
        loadRewardedAd();
        if (!hasEarned) onEarnedReward(false);
      },
      onAdFailedToShowFullScreenContent: (a, error) {
        a.dispose();
        _rewardedAd = null;
        _isRewardedShowing = false;
        onEarnedReward(false);
      },
      onAdClicked: (a) => AdSafetyConfig.recordAdClick(),
    );
    ad.show(onUserEarnedReward: (AdWithoutView a, RewardItem reward) {
      SafeLogger.d(_tag, '🏆 showRewardedAd [AdMob] Earned: type=${reward.type}, amount=${reward.amount}');
      hasEarned = true;
      onEarnedReward(true);
    });
  }

  void _showRewardedAppLovin(void Function(bool) onEarnedReward) {
    if (_isRewardedShowing || !_isMaxRewardedReady) { onEarnedReward(false); return; }
    _isMaxRewardedReady = false;
    _isRewardedShowing = true;
    _pendingRewardedDoneFlow = (earned) {
      _isRewardedShowing = false;
      onEarnedReward(earned);
    };
    AppLovinMAX.showRewardedAd(_config.appLovin!.rewardedId);
  }

  // ════════════════════════════════════════════════════
  // SPLASH FLOW
  // ════════════════════════════════════════════════════
  void markSplashActive() {
    _isSplashActive = true;
    SafeLogger.d(_tag, 'markSplashActive');
  }

  void markSplashInactive() {
    _isSplashActive = false;
    SafeLogger.d(_tag, 'markSplashInactive');
  }

  bool get isSplashActive => _isSplashActive;
  int get countInitSplashScreen => _countInitSplashScreen;

  /// AppLovin banner ad unit ID (read-only, set by [AdConfig]).
  String get appLovinBannerId => _initialized ? (_config.appLovin?.bannerId ?? '') : '';

  /// Whether AdMob is the active provider.
  bool get isAdMobProvider => _initialized && _config.isAdMob;

  void incrementSplashCount() {
    _countInitSplashScreen++;
    SafeLogger.d(_tag, 'incrementSplashCount count=$_countInitSplashScreen');
  }

  // ════════════════════════════════════════════════════
  // VIP MANAGEMENT
  // ════════════════════════════════════════════════════
  void addVIPMember(List<String> gaids) {
    _setGAIDVipMember.addAll(gaids);
    AdPreferences.instanceOrNull?.saveGAIDList(_setGAIDVipMember.toList());
    _isVipMember = _setGAIDVipMember.contains(_currentDeviceGAID);
    SafeLogger.d(_tag, 'addVIPMember: ${gaids.length} added → isVIP=$_isVipMember');
  }

  void deleteVIPMember(List<String> gaids) {
    for (final g in gaids) { _setGAIDVipMember.remove(g); }
    AdPreferences.instanceOrNull?.saveGAIDList(_setGAIDVipMember.toList());
    _isVipMember = _setGAIDVipMember.contains(_currentDeviceGAID);
    SafeLogger.d(_tag, 'deleteVIPMember: ${gaids.length} removed → isVIP=$_isVipMember');
  }

  bool isVIPMember() {
    SafeLogger.d(_tag, 'isVIPMember() = $_isVipMember, GAID=$_currentDeviceGAID');
    return _isVipMember;
  }

  // ════════════════════════════════════════════════════
  // BANNER GUARD
  // ════════════════════════════════════════════════════
  bool canLoadBanner() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastBannerLoadTime;
    if (_lastBannerLoadTime > 0 && elapsed < _bannerLoadCooldown) return false;
    return true;
  }

  void recordBannerLoad() {
    _lastBannerLoadTime = DateTime.now().millisecondsSinceEpoch;
  }

  // ════════════════════════════════════════════════════
  // PRE-CHECK
  // ════════════════════════════════════════════════════

  /// Returns true if an interstitial ad can be shown right now.
  bool canShowInterstitial() {
    _assertInitialized();
    if (_isVipMember || _isInterstitialShowing) return false;
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) return false;
    return _isAdmob ? (_interstitialAd != null) : _isMaxInterReady;
  }

  /// Returns true if a rewarded ad can be shown right now.
  bool canShowRewardedAd() {
    _assertInitialized();
    if (_isVipMember) return true; // VIP auto-reward
    if (_isRewardedShowing) return false;
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) return false;
    return _isAdmob ? (_rewardedAd != null) : _isMaxRewardedReady;
  }

  // ════════════════════════════════════════════════════
  // DESTROY
  // ════════════════════════════════════════════════════

  /// Release all ad resources. Call only when you truly need a full reset.
  ///
  /// ⚠️ After destroy, [AdManager] singleton will no longer respond to
  /// lifecycle events. You must call [initialize] again before using ads.
  void destroy() {
    SafeLogger.d(_tag, 'destroy() called — releasing all ad resources');

    // Remove lifecycle observer — prevents memory leak from dangling observer
    SafeLogger.d(_tag, 'destroy() removing WidgetsBinding observer');
    WidgetsBinding.instance.removeObserver(this);

    // AdMob cleanup — null fullScreenContentCallback BEFORE dispose to avoid late callbacks
    SafeLogger.d(_tag, 'destroy() [AdMob] disposing interstitialAd=${_interstitialAd != null}');
    _interstitialAd?.fullScreenContentCallback = null;
    _interstitialAd?.dispose();
    _interstitialAd = null;

    SafeLogger.d(_tag, 'destroy() [AdMob] disposing appOpenAd=${_appOpenAd != null}');
    _appOpenAd?.fullScreenContentCallback = null;
    _appOpenAd?.dispose();
    _appOpenAd = null;

    SafeLogger.d(_tag, 'destroy() [AdMob] disposing rewardedAd=${_rewardedAd != null}');
    _rewardedAd?.fullScreenContentCallback = null;
    _rewardedAd?.dispose();
    _rewardedAd = null;

    SafeLogger.d(_tag, 'destroy() [AdMob] disposing admobBannerAd=${_admobBannerAd != null}');
    _admobBannerAd?.dispose();
    _admobBannerAd = null;

    // AppLovin cleanup — reset all state flags
    SafeLogger.d(_tag, 'destroy() [AppLovin] resetting state: appOpen=$_isMaxAppOpenReady, inter=$_isMaxInterReady, rewarded=$_isMaxRewardedReady');
    _isMaxAppOpenReady = false;
    _isMaxAppOpenShowing = false;
    _isMaxInterReady = false;
    _isInterLoading = false;
    _isInterstitialShowing = false;
    _isMaxRewardedReady = false;
    _isRewardedLoading = false;
    _isRewardedShowing = false;
    _pendingInterDoneFlow = null;
    _onAppOpenDismissed = null;
    _pendingAppOpenLoadCallback = null;
    _pendingRewardedDoneFlow = null;

    // Common flags
    _isAppOpenShowing = false;
    _isAppOpenLoading = false;

    // Banner — reset ValueNotifier values (but do NOT dispose — they are
    // final fields that live for the entire singleton lifetime)
    SafeLogger.d(_tag, 'destroy() resetting banner ValueNotifier values');
    bannerIsLoaded.value = false;
    bannerHasError.value = false;
    bannerAdViewId.value = null;
    bannerAutoRefreshEnabled.value = true;
    bannerVisible.value = true;
    bannerAdSize.value = null;

    SafeLogger.d(_tag, 'destroy() ✅ all ad resources released');
  }
}
