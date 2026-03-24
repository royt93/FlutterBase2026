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
import '../widget/ad_loading_dialog.dart';

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
    _ensureObserverAdded();
  }

  bool _isObserverAdded = false;
  void _ensureObserverAdded() {
    if (!_isObserverAdded) {
      WidgetsBinding.instance.addObserver(this);
      _isObserverAdded = true;
    }
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

  // ════════ NAVIGATOR KEY (for showing dialogs from lifecycle observer) ════════
  GlobalKey<NavigatorState>? _navigatorKey;

  /// Register the app's navigator key so the SDK can show loading dialogs
  /// from lifecycle callbacks (e.g. App Open on resume) without a BuildContext.
  ///
  /// Call this in `main()` or early in your app:
  /// ```dart
  /// AdManager().setNavigatorKey(navigatorKey);
  /// ```
  void setNavigatorKey(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
    SafeLogger.d(_tag, 'setNavigatorKey: registered ✅');
  }

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
  bool _isInitializing = false; // Fix #36: concurrent initialize() guard
  int _lastFullscreenDismissTime = 0; // Fix #46: tracks when last fullscreen ad was dismissed

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
    // Fix #19: if called again without destroy(), clean up old resources first
    if (_initialized) {
      SafeLogger.w(_tag, '###init called again without destroy() — auto-cleaning old resources');
      _cleanupOldAds();
    }

    // Fix #36: guard against concurrent async initialize() calls
    if (_isInitializing) {
      SafeLogger.w(_tag, '###init already in progress — skipping duplicate call');
      return;
    }
    _isInitializing = true;

    _config = config;
    _initialized = true;
    // Fix #34: configure log level EARLY so init logs respect AdLogLevel.none
    SafeLogger.setEnabled(config.logLevel != AdLogLevel.none);
    _ensureObserverAdded(); // Fix O: re-add lifecycle observer after destroy()
    SafeLogger.d(_tag, '###init called, provider=${config.provider}');

    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs);

    // Load VIP GAIDs from SharedPreferences
    _setGAIDVipMember.clear(); // Fix #7: prevent accumulation on reinit
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

    try {
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
    } catch (e) {
      // Fix #38: SDK init failed — release mutex and notify caller
      SafeLogger.e(_tag, '###init SDK initialization FAILED: $e');
      _isInitializing = false;
      onComplete(false, _currentDeviceGAID);
      SimpleEventBus().fire(const BoolEvent(false));
      return;
    }

    SafeLogger.d(_tag, '###init completed');
    _isInitializing = false; // Fix #36: release init mutex
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

    // Start periodic retry timer to refill expired/failed ads
    _startAdRetryTimer();
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
          AdSafetyConfig.recordBannerImpression(); // Fix J
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
    // Fix #28: reset banner loaded state so shimmer shows during reload
    bannerIsLoaded.value = false;
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
            AdSafetyConfig.recordBannerImpression(); // Fix J
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
        _isAppOpenLoading = false;
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
        _isAppOpenLoading = false;
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
        _onAppOpenDismissed?.call(false);
        _onAppOpenDismissed = null;
        // Reload so the next attempt has a fresh ad
        AppLovinMAX.loadAppOpenAd(appOpenId);
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
        // Reload so the next attempt has a fresh ad
        AppLovinMAX.loadInterstitial(interId);
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
        _lastFullscreenDismissTime = DateTime.now().millisecondsSinceEpoch; // Fix #46
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
        _isRewardedLoading = false; // Fix #4: was missing → stuck true after first load
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
        // Reload so the next attempt has a fresh ad
        AppLovinMAX.loadRewardedAd(rewardedId);
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
        _lastFullscreenDismissTime = DateTime.now().millisecondsSinceEpoch; // Fix #46
        // ⚠️ BUG FIX: if reward was NOT earned (user skipped), _pendingRewardedDoneFlow
        // is still set because onAdReceivedRewardCallback was never called.
        // We must call it with false here to avoid the loading dialog hanging forever.
        if (_pendingRewardedDoneFlow != null) {
          SafeLogger.w(_tag, '⚠️ [AppLovin] Rewarded dismissed WITHOUT reward — calling pending flow(false)');
          _pendingRewardedDoneFlow?.call(false);
          _pendingRewardedDoneFlow = null;
        }
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
    if (_isVipMember) { onAdLoaded?.call(false); return; }
    if (!isConnected) { onAdLoaded?.call(false); return; }
    if (_isCooldown(_lastAppOpenErrorTime)) { onAdLoaded?.call(false); return; }
    // Guard against duplicate in-flight loads — checked before logging to avoid spam
    if (_isAppOpenLoading) {
      SafeLogger.d(_tag, 'loadAppOpenAd $_provider ⏭️ already loading, skip');
      onAdLoaded?.call(false);
      return;
    }
    SafeLogger.d(_tag, 'loadAppOpenAd $_provider called, isVIP=$_isVipMember');

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
      // Fix #24: dispose the expired ad before loading a new one
      _appOpenAd!.fullScreenContentCallback = null;
      _appOpenAd!.dispose();
      _appOpenAd = null;
      _appOpenAdLoadTime = null;
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
    _isAppOpenLoading = true;
    // Fix #8: call old callback before overwriting to avoid swallowed callbacks
    if (_pendingAppOpenLoadCallback != null) {
      SafeLogger.w(_tag, 'loadAppOpenAd [AppLovin] ⚠️ overwriting pending callback → calling old one with false');
      _pendingAppOpenLoadCallback?.call(false);
    }
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
        _lastFullscreenDismissTime = DateTime.now().millisecondsSinceEpoch; // Fix #46
        onAdDismiss(true);
        loadAppOpenAd(); // Fix #41: reload after dismiss to keep slot filled (matches AppLovin path)
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _appOpenAd = null;
        _isAppOpenShowing = false;
        onAdDismiss(false); // Fix Y: was true, but ad was NOT shown
        loadAppOpenAd(); // Reload for next attempt
      },
      onAdClicked: (ad) => AdSafetyConfig.recordAdClick(),
      onAdImpression: (ad) {},
    );
    ad.show();
  }

  void _showAppOpenAdAppLovin(void Function(bool) onAdDismiss) {
    final appOpenId = _config.appLovin!.appOpenId;
    if (!_isMaxAppOpenReady) {
      SafeLogger.w(_tag, '_showAppOpenAdAppLovin: ad not ready \u2192 onAdDismiss(false)');
      onAdDismiss(false);
      return;
    }
    if (_isMaxAppOpenShowing) {
      SafeLogger.w(_tag, '_showAppOpenAdAppLovin: already showing \u2192 onAdDismiss(false)');
      onAdDismiss(false);
      return;
    }
    _onAppOpenDismissed = onAdDismiss;
    SafeLogger.d(_tag, '_showAppOpenAdAppLovin: calling AppLovinMAX.showAppOpenAd');
    AppLovinMAX.showAppOpenAd(appOpenId);

    // Fix #17: capture callback ref locally to detect race with onAdDisplayFailedCallback.
    // If the callback was already consumed by the listener before timeout fires,
    // the local ref still points to the old callback but _onAppOpenDismissed is null.
    final capturedCallback = onAdDismiss;
    const kTimeoutMs = 10000;
    Future.delayed(const Duration(milliseconds: kTimeoutMs), () {
      // Only fire if OUR callback is still the pending one (not consumed by listener)
      if (_onAppOpenDismissed == capturedCallback && !_isMaxAppOpenShowing) {
        SafeLogger.e(_tag, '⚠️ _showAppOpenAdAppLovin: TIMEOUT after ${kTimeoutMs}ms — ad never displayed, force-calling onAdDismiss(false)');
        _onAppOpenDismissed = null;
        _isMaxAppOpenShowing = false;
        capturedCallback(false);
      }
    });
  }

  // ════════════════════════════════════════════════════
  // APP OPEN ON RESUME
  // ════════════════════════════════════════════════════
  void showAppOpenAdOnResume() {
    // Fix #33: guard against LateInitializationError — this is a public method
    // that could be called before initialize() sets _config (late field).
    if (!_initialized) {
      SafeLogger.d(_tag, '▶️ showAppOpenAdOnResume SKIPPED (not initialized)');
      return;
    }
    SafeLogger.d(_tag, '▶️ showAppOpenAdOnResume $_provider triggered! isSplash=$_isSplashActive, isVIP=$_isVipMember');
    if (_isSplashActive || _isVipMember) return;
    if (_isInterstitialShowing || _isRewardedShowing) return;

    // Fix #46: interstitial/rewarded dismiss callback fires BEFORE lifecycle
    // resumed — so _isInterstitialShowing is already false by this point.
    // Use timestamp instead to catch the edge case.
    final timeSinceDismiss = DateTime.now().millisecondsSinceEpoch - _lastFullscreenDismissTime;
    if (_lastFullscreenDismissTime > 0 && timeSinceDismiss < 2000) {
      SafeLogger.d(_tag, '▶️ showAppOpenAdOnResume SKIPPED (fullscreen dismissed ${timeSinceDismiss}ms ago)');
      return;
    }

    if (!AdSafetyConfig.canShowAppOpenOnResume()) {
      loadAppOpenAd();
      return;
    }

    final adReady = _isAdmob ? (_appOpenAd != null) : _isMaxAppOpenReady;
    final isShowing = _isAdmob ? _isAppOpenShowing : _isMaxAppOpenShowing;

    if (adReady && !isShowing) {
      // Fix #47: Show actual AdLoadingDialog before App Open on resume.
      // Uses navigator key to show dialog without BuildContext.
      final navKey = _navigatorKey;
      final navContext = navKey?.currentContext;
      if (navContext != null) {
        SafeLogger.d(_tag, '▶️ showAppOpenAdOnResume: showing loading dialog...');
        AdLoadingDialog.showAdBuffer(navContext, onComplete: () {
          // Re-check conditions after dialog — user may have triggered another ad
          if (_isSplashActive || _isVipMember || _isInterstitialShowing || _isRewardedShowing) return;
          final stillReady = _isAdmob ? (_appOpenAd != null) : _isMaxAppOpenReady;
          final nowShowing = _isAdmob ? _isAppOpenShowing : _isMaxAppOpenShowing;
          if (!stillReady || nowShowing) {
            loadAppOpenAd();
            return;
          }
          showAppOpenAd(
            onAdDismiss: (wasActuallyShown) => loadAppOpenAd(),
            bypassSafety: true, // Fix #3: canShowAppOpenOnResume() already checked above
          );
        });
      } else {
        // Fallback: no navigator key — use delay buffer
        SafeLogger.w(_tag, '▶️ showAppOpenAdOnResume: no navigator context, using delay fallback...');
        Future.delayed(const Duration(seconds: 1), () {
          if (_isSplashActive || _isVipMember || _isInterstitialShowing || _isRewardedShowing) return;
          final stillReady = _isAdmob ? (_appOpenAd != null) : _isMaxAppOpenReady;
          final nowShowing = _isAdmob ? _isAppOpenShowing : _isMaxAppOpenShowing;
          if (!stillReady || nowShowing) {
            loadAppOpenAd();
            return;
          }
          showAppOpenAd(
            onAdDismiss: (wasActuallyShown) => loadAppOpenAd(),
            bypassSafety: true,
          );
        });
      }
    } else {
      loadAppOpenAd();
    }
  }

  // ════════════════════════════════════════════════════
  // LIFECYCLE OBSERVER
  // ════════════════════════════════════════════════════
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Fix #29: guard against LateInitializationError — lifecycle events
    // can fire before initialize() sets _config (late field).
    if (!_initialized) {
      SafeLogger.d(_tag, 'didChangeAppLifecycleState: state=$state — SKIPPED (not initialized)');
      return;
    }
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
          // Fix #14: previously only cleared the flag but never reloaded.
          // Now trigger a fresh load so banner fills after resume.
          bannerHasError.value = false;
          // Fix #40: guard against empty views (edge case during background transition)
          final views = WidgetsBinding.instance.platformDispatcher.views;
          if (views.isEmpty) {
            SafeLogger.w(_tag, 'lifecycle-resumed: platformDispatcher.views is empty — skipping banner reload');
          } else {
            final view = views.first;
            final width = view.physicalSize.width / view.devicePixelRatio;
            loadAdmobBannerIfNeeded(width);
          }
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
    SafeLogger.d(_tag, 'showInterstitial $_provider called, isVIP=$_isVipMember, isAlreadyShowing=$_isInterstitialShowing');
    if (_isVipMember) {
      SafeLogger.d(_tag, 'showInterstitial ⏭️ VIP → skip');
      onDoneFlow(false);
      return;
    }

    // ✅ FIX 2: Early concurrent guard — set flag NOW before the dialog buffer,
    // not inside _showInterstitialAppLovin (which runs after 1s buffer).
    // Without this, a second tap during the 1s buffer passes canShowInterstitial()
    // and shows a SECOND loading dialog, corrupting the navigator stack.
    if (_isInterstitialShowing) {
      SafeLogger.w(_tag, 'showInterstitial ⚠️ already showing — skipping duplicate call');
      onDoneFlow(false);
      return;
    }
    _isInterstitialShowing = true;
    SafeLogger.d(_tag, 'showInterstitial: locked _isInterstitialShowing=true early');

    final safetyResult = AdSafetyConfig.canShowFullscreenAd();
    if (!safetyResult.canShow) {
      _isInterstitialShowing = false; // release lock on safety failure
      SafeLogger.w(_tag, 'showInterstitial ⚠️ safety re-check failed: ${safetyResult.reason} → calling onDoneFlow(false)');
      onDoneFlow(false);
      return;
    }

    if (_isAdmob) {
      _showInterstitialAdmob(onDoneFlow);
    } else {
      _showInterstitialAppLovin(onDoneFlow);
    }
  }

  void _showInterstitialAdmob(void Function(bool) onDoneFlow) {
    final ad = _interstitialAd;
    if (ad == null) {
      _isInterstitialShowing = false; // release early lock
      SafeLogger.w(_tag, '_showInterstitialAdmob: ad is null → onDoneFlow(false)');
      onDoneFlow(false);
      return;
    }
    // _isInterstitialShowing already set true by showInterstitial() early lock
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (a) => AdSafetyConfig.recordFullscreenAdShown(),
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _interstitialAd = null;
        _isInterstitialShowing = false;
        _lastFullscreenDismissTime = DateTime.now().millisecondsSinceEpoch; // Fix #46
        loadInterstitial();
        onDoneFlow(true);
      },
      onAdFailedToShowFullScreenContent: (a, error) {
        a.dispose();
        _interstitialAd = null;
        _isInterstitialShowing = false;
        onDoneFlow(false);
        loadInterstitial(); // Fix #1: reload after show-fail
      },
      onAdClicked: (a) => AdSafetyConfig.recordAdClick(),
    );
    ad.show();
  }

  void _showInterstitialAppLovin(void Function(bool) onDoneFlow) {
    if (!_isMaxInterReady) {
      _isInterstitialShowing = false; // release early lock
      SafeLogger.w(_tag, '_showInterstitialAppLovin: ad not ready \u2192 onDoneFlow(false)');
      onDoneFlow(false);
      return;
    }
    _isMaxInterReady = false;
    // _isInterstitialShowing already set true by showInterstitial() early lock
    _pendingInterDoneFlow = onDoneFlow;
    SafeLogger.d(_tag, '_showInterstitialAppLovin: calling AppLovinMAX.showInterstitial');
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
    SafeLogger.d(_tag, 'showRewardedAd $_provider called, isVIP=$_isVipMember, isAlreadyShowing=$_isRewardedShowing');
    if (_isVipMember) {
      SafeLogger.d(_tag, 'showRewardedAd ✅ VIP → auto-reward');
      onEarnedReward(true);
      return;
    }

    // ✅ FIX: Early concurrent guard — mirrors the interstitial fix.
    // Prevents double-tap from launching two rewarded flows simultaneously.
    if (_isRewardedShowing) {
      SafeLogger.w(_tag, 'showRewardedAd ⚠️ already showing — skipping duplicate call');
      onEarnedReward(false);
      return;
    }
    _isRewardedShowing = true;
    SafeLogger.d(_tag, 'showRewardedAd: locked _isRewardedShowing=true early');

    final safetyResult = AdSafetyConfig.canShowFullscreenAd();
    if (!safetyResult.canShow) {
      _isRewardedShowing = false; // release early lock
      SafeLogger.w(_tag, 'showRewardedAd ⚠️ safety re-check failed: ${safetyResult.reason} → calling onEarnedReward(false)');
      onEarnedReward(false);
      return;
    }

    if (_isAdmob) {
      _showRewardedAdmob(onEarnedReward);
    } else {
      _showRewardedAppLovin(onEarnedReward);
    }
  }

  void _showRewardedAdmob(void Function(bool) onEarnedReward) {
    final ad = _rewardedAd;
    if (ad == null) {
      _isRewardedShowing = false; // release early lock
      SafeLogger.w(_tag, '_showRewardedAdmob: ad is null → onEarnedReward(false)');
      onEarnedReward(false);
      return;
    }
    // _isRewardedShowing already set true by showRewardedAd() early lock
    bool hasEarned = false;
    bool callbackFired = false; // Fix #42: guard against double callback
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (a) => AdSafetyConfig.recordFullscreenAdShown(),
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        _rewardedAd = null;
        _isRewardedShowing = false;
        _lastFullscreenDismissTime = DateTime.now().millisecondsSinceEpoch; // Fix #46
        loadRewardedAd();
        // Fix #42: only call if reward callback hasn't fired yet
        if (!hasEarned && !callbackFired) {
          callbackFired = true;
          onEarnedReward(false);
        }
      },
      onAdFailedToShowFullScreenContent: (a, error) {
        a.dispose();
        _rewardedAd = null;
        _isRewardedShowing = false;
        if (!callbackFired) {
          callbackFired = true;
          onEarnedReward(false);
        }
        loadRewardedAd(); // Fix #2: reload after show-fail
      },
      onAdClicked: (a) => AdSafetyConfig.recordAdClick(),
    );
    ad.show(onUserEarnedReward: (AdWithoutView a, RewardItem reward) {
      SafeLogger.d(_tag, '🏆 showRewardedAd [AdMob] Earned: type=${reward.type}, amount=${reward.amount}');
      hasEarned = true;
      if (!callbackFired) {
        callbackFired = true;
        onEarnedReward(true);
      }
    });
  }

  void _showRewardedAppLovin(void Function(bool) onEarnedReward) {
    if (!_isMaxRewardedReady) {
      _isRewardedShowing = false; // release early lock
      SafeLogger.w(_tag, '_showRewardedAppLovin: ad not ready → onEarnedReward(false)');
      onEarnedReward(false);
      return;
    }
    _isMaxRewardedReady = false;
    // _isRewardedShowing already set true by showRewardedAd() early lock
    _pendingRewardedDoneFlow = (earned) {
      _isRewardedShowing = false;
      onEarnedReward(earned);
    };
    SafeLogger.d(_tag, '_showRewardedAppLovin: calling AppLovinMAX.showRewardedAd');
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
    if (AdLoadingDialog.isShowing) return false; // dialog buffer active
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) return false;
    return _isAdmob ? (_interstitialAd != null) : _isMaxInterReady;
  }

  /// Returns true if a rewarded ad can be shown right now.
  bool canShowRewardedAd() {
    _assertInitialized();
    if (_isVipMember) return true; // VIP auto-reward
    if (_isRewardedShowing) return false;
    if (AdLoadingDialog.isShowing) return false; // dialog buffer active
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.canShow) return false;
    return _isAdmob ? (_rewardedAd != null) : _isMaxRewardedReady;
  }

  // ════════════════════════════════════════════════════
  // DESTROY
  // ════════════════════════════════════════════════════

  /// Lightweight cleanup of old ad objects when [initialize] is called again
  /// without a prior [destroy]. Prevents native ad memory leaks.
  void _cleanupOldAds() {
    _interstitialAd?.fullScreenContentCallback = null;
    _interstitialAd?.dispose();
    _interstitialAd = null;
    _appOpenAd?.fullScreenContentCallback = null;
    _appOpenAd?.dispose();
    _appOpenAd = null;
    _rewardedAd?.fullScreenContentCallback = null;
    _rewardedAd?.dispose();
    _rewardedAd = null;
    _admobBannerAd?.dispose();
    _admobBannerAd = null;
    // Fix #37: reset banner ValueNotifiers so next BannerAdWidget shows shimmer, not stale state
    bannerIsLoaded.value = false;
    bannerHasError.value = false;
    bannerAdSize.value = null;
    _stopAdRetryTimer();
    SafeLogger.d(_tag, '_cleanupOldAds() done');
  }

  /// Release all ad resources. Call only when you truly need a full reset.
  ///
  /// ⚠️ After destroy, [AdManager] singleton will no longer respond to
  /// lifecycle events. You must call [initialize] again before using ads.
  void destroy() {
    SafeLogger.d(_tag, 'destroy() called — releasing all ad resources');

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

    // Fix #20: fire pending callbacks BEFORE nulling so callers aren't left hanging
    if (_pendingInterDoneFlow != null) {
      SafeLogger.w(_tag, 'destroy() firing pending interstitial callback(false)');
      _pendingInterDoneFlow?.call(false);
    }
    if (_onAppOpenDismissed != null) {
      SafeLogger.w(_tag, 'destroy() firing pending app open callback(false)');
      _onAppOpenDismissed?.call(false);
    }
    if (_pendingAppOpenLoadCallback != null) {
      SafeLogger.w(_tag, 'destroy() firing pending app open load callback(false)');
      _pendingAppOpenLoadCallback?.call(false);
    }
    if (_pendingRewardedDoneFlow != null) {
      SafeLogger.w(_tag, 'destroy() firing pending rewarded callback(false)');
      _pendingRewardedDoneFlow?.call(false);
    }

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
    _lastFullscreenDismissTime = 0; // Fix #46: reset dismiss timestamp
    _pendingInterDoneFlow = null;
    _onAppOpenDismissed = null;
    _pendingAppOpenLoadCallback = null;
    _pendingRewardedDoneFlow = null;
    _isFirstAdLoadTriggered = false; // Fix V: reset so Inter+Rewarded get preloaded on reinit

    // Common flags
    _isAppOpenShowing = false;
    _isAppOpenLoading = false;
    _isInitializing = false; // Fix #39: reset init mutex in destroy
    _bannerRoutePaused = false; // Fix #25: reset banner pause flag
    _isSplashActive = false; // Fix #26: reset splash flag for clean reinit
    _countInitSplashScreen = 0; // Fix #27: reset splash count for clean reinit

    // Fix #18: reset error cooldown timestamps so reinit doesn't carry stale cooldowns
    _lastAppOpenErrorTime = 0;
    _lastInterErrorTime = 0;
    _lastRewardedErrorTime = 0;
    _appOpenAdLoadTime = null;
    _lastBannerLoadTime = 0; // Fix #21: reset banner cooldown

    // Fix #22: reset AdLoadingDialog static flag
    AdLoadingDialog.resetState();

    // Banner — reset ValueNotifier values (but do NOT dispose — they are
    // final fields that live for the entire singleton lifetime)
    SafeLogger.d(_tag, 'destroy() resetting banner ValueNotifier values');
    bannerIsLoaded.value = false;
    bannerHasError.value = false;
    bannerAdViewId.value = null;
    bannerAutoRefreshEnabled.value = true;
    bannerVisible.value = true;
    bannerAdSize.value = null;

    // Reset AdSafetyConfig for clean re-init (cold start, session, etc.)
    AdSafetyConfig.resetForReinit();

    // Clear EventBus listeners to prevent memory leaks (Fix N)
    SimpleEventBus().clearAll();

    // Stop retry timer
    _stopAdRetryTimer();

    // Remove lifecycle observer — it will be re-added on next initialize()
    SafeLogger.d(_tag, 'destroy() removing WidgetsBinding observer');
    WidgetsBinding.instance.removeObserver(this);
    _isObserverAdded = false;

    _initialized = false;
    SafeLogger.d(_tag, 'destroy() ✅ all ad resources released');
  }

  // ════════════════════════════════════════════════════
  // PERIODIC AD RETRY TIMER (Fix R / T)
  // ════════════════════════════════════════════════════
  static const int _retryIntervalMs = 5 * 60 * 1000; // 5 min
  bool _retryTimerActive = false;

  void _startAdRetryTimer() {
    if (_retryTimerActive) return;
    _retryTimerActive = true;
    SafeLogger.d(_tag, '⏲️ Ad retry timer started (every ${_retryIntervalMs ~/ 1000}s)');
    _scheduleNextRetry();
  }

  void _scheduleNextRetry() {
    Future.delayed(Duration(milliseconds: _retryIntervalMs), () {
      if (!_retryTimerActive || !_initialized) return;
      _retryRefillAds();
      _scheduleNextRetry(); // reschedule
    });
  }

  void _stopAdRetryTimer() {
    _retryTimerActive = false;
    SafeLogger.d(_tag, '⏲️ Ad retry timer stopped');
  }

  /// Proactively refill any empty ad slots.
  void _retryRefillAds() {
    SafeLogger.d(_tag, '⏲️ Ad retry timer fired — checking fill status');

    // App Open: check AdMob expiry (4h) or AppLovin not ready
    if (_isAdmob) {
      if (_appOpenAd != null && _appOpenAdLoadTime != null) {
        if (DateTime.now().difference(_appOpenAdLoadTime!).inHours >= 4) {
          SafeLogger.d(_tag, '⏲️ AdMob App Open expired (>4h) — reloading');
          // Fix #30: null callback BEFORE dispose to prevent stale native callback
          _appOpenAd?.fullScreenContentCallback = null;
          _appOpenAd?.dispose();
          _appOpenAd = null;
          _appOpenAdLoadTime = null;
          loadAppOpenAd();
        }
      } else if (_appOpenAd == null && !_isAppOpenLoading) {
        loadAppOpenAd();
      }
    } else {
      if (!_isMaxAppOpenReady && !_isAppOpenLoading) loadAppOpenAd();
    }

    // Interstitial
    if (_isAdmob) {
      if (_interstitialAd == null && !_isInterLoading) loadInterstitial();
    } else {
      if (!_isMaxInterReady && !_isInterLoading) loadInterstitial();
    }

    // Rewarded
    if (_isAdmob) {
      if (_rewardedAd == null && !_isRewardedLoading) loadRewardedAd();
    } else {
      if (!_isMaxRewardedReady && !_isRewardedLoading) loadRewardedAd();
    }
  }
}
