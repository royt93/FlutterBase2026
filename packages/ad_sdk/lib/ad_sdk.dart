/// ad_sdk — Dual-provider Flutter Ad SDK
///
/// Supports AdMob (Google Mobile Ads) and AppLovin MAX via a single API.
///
/// ## Quick Start
/// ```dart
/// // 1. In main.dart, initialize before runApp():
/// await AdManager().initialize(
///   config: AdConfig(
///     provider: AdProvider.appLovin,
///     appLovin: AppLovinConfig(
///       sdkKey: 'YOUR_SDK_KEY',
///       bannerId: 'YOUR_BANNER_ID',
///       interstitialId: 'YOUR_INTER_ID',
///       appOpenId: 'YOUR_APP_OPEN_ID',
///       rewardedId: 'YOUR_REWARDED_ID',
///     ),
///   ),
///   onComplete: (success, gaid) {},
/// );
///
/// // 2. Add route observers to your app:
/// navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
///
/// // 3. Extend AdScreen on screens with ads:
/// class HomeScreen extends AdScreen { ... }
/// class _HomeScreenState extends AdScreenState<HomeScreen> {
///   Widget build(context) => Column(children: [buildBanner(), ...]);
/// }
/// ```
library ad_sdk;

export 'src/config/ad_config.dart';
export 'src/core/ad_manager.dart';
export 'src/core/ad_screen.dart';
export 'src/core/ad_route_observer.dart';
export 'src/core/ad_safety_config.dart'
    show AdSafetyConfig, AdSafetyParams, AdSafetyResult;
export 'src/utils/safe_logger.dart';
export 'src/core/event_bus.dart';
export 'src/widget/banner_ad_widget.dart';
export 'src/widget/ad_loading_dialog.dart';
export 'src/widget/top_toast.dart';
