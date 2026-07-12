import 'package:applovin_max/applovin_max.dart';

/// Thin seam over the static `AppLovinMAX` plugin API.
///
/// [AppLovinAdapter] calls every native AppLovin method through this interface
/// instead of touching `AppLovinMAX.*` directly. Production uses
/// [RealAppLovinBridge] (the default); tests inject a fake that captures the
/// listeners and records load/show calls, so the adapter's wiring, watchdog,
/// reload-after-fail and reward logic can be exercised without the native SDK.
abstract class AppLovinBridge {
  Future<void> initialize(String sdkKey);
  void setTestDeviceAdvertisingIds(List<String> ids);

  /// Enable/disable AppLovin's OWN Terms & Privacy Policy (CMP) flow. The SDK
  /// disables it when Google UMP is the consent source (T01) to avoid a double
  /// consent prompt. See [AppLovinBridge].
  void setTermsAndPrivacyPolicyFlowEnabled(bool enabled);

  void setAppOpenAdListener(AppOpenAdListener? listener);
  void setInterstitialListener(InterstitialListener? listener);
  void setRewardedAdListener(RewardedAdListener? listener);
  void setWidgetAdViewAdListener(WidgetAdViewAdListener? listener);

  void loadAppOpenAd(String adUnitId);
  void showAppOpenAd(String adUnitId);
  void loadInterstitial(String adUnitId);
  void showInterstitial(String adUnitId);
  void loadRewardedAd(String adUnitId);

  /// [customData] is AppLovin's own SSV passthrough field — forwarded
  /// verbatim to `AppLovinMAX.showRewardedAd`'s `customData` param, which
  /// AppLovin includes in its server-to-server reward postback. Null/omitted
  /// preserves today's behavior exactly.
  void showRewardedAd(String adUnitId, {String? customData});

  Future<AdViewId?> preloadWidgetAdView(String adUnitId, AdFormat adFormat);
  Future<void> destroyWidgetAdView(AdViewId adViewId);
}

/// Production bridge — forwards every call to the real `AppLovinMAX` plugin.
class RealAppLovinBridge implements AppLovinBridge {
  const RealAppLovinBridge();

  @override
  Future<void> initialize(String sdkKey) => AppLovinMAX.initialize(sdkKey);

  @override
  void setTestDeviceAdvertisingIds(List<String> ids) =>
      AppLovinMAX.setTestDeviceAdvertisingIds(ids);

  @override
  void setTermsAndPrivacyPolicyFlowEnabled(bool enabled) =>
      AppLovinMAX.setTermsAndPrivacyPolicyFlowEnabled(enabled);

  @override
  void setAppOpenAdListener(AppOpenAdListener? listener) =>
      AppLovinMAX.setAppOpenAdListener(listener);

  @override
  void setInterstitialListener(InterstitialListener? listener) =>
      AppLovinMAX.setInterstitialListener(listener);

  @override
  void setRewardedAdListener(RewardedAdListener? listener) =>
      AppLovinMAX.setRewardedAdListener(listener);

  @override
  void setWidgetAdViewAdListener(WidgetAdViewAdListener? listener) =>
      AppLovinMAX.setWidgetAdViewAdListener(listener);

  @override
  void loadAppOpenAd(String adUnitId) => AppLovinMAX.loadAppOpenAd(adUnitId);

  @override
  void showAppOpenAd(String adUnitId) => AppLovinMAX.showAppOpenAd(adUnitId);

  @override
  void loadInterstitial(String adUnitId) =>
      AppLovinMAX.loadInterstitial(adUnitId);

  @override
  void showInterstitial(String adUnitId) =>
      AppLovinMAX.showInterstitial(adUnitId);

  @override
  void loadRewardedAd(String adUnitId) => AppLovinMAX.loadRewardedAd(adUnitId);

  @override
  void showRewardedAd(String adUnitId, {String? customData}) =>
      AppLovinMAX.showRewardedAd(adUnitId, customData: customData);

  @override
  Future<AdViewId?> preloadWidgetAdView(String adUnitId, AdFormat adFormat) =>
      AppLovinMAX.preloadWidgetAdView(adUnitId, adFormat);

  @override
  Future<void> destroyWidgetAdView(AdViewId adViewId) =>
      AppLovinMAX.destroyWidgetAdView(adViewId);
}
