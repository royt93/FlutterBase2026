/// Ad provider selection.
enum AdProvider {
  /// Google AdMob (google_mobile_ads package)
  admob,

  /// AppLovin MAX (applovin_max package)
  appLovin,
}

/// AppLovin MAX ad unit IDs configuration.
class AppLovinConfig {
  /// AppLovin SDK Key (from MAX dashboard)
  final String sdkKey;

  /// Banner ad unit ID
  final String bannerId;

  /// Interstitial ad unit ID
  final String interstitialId;

  /// App Open ad unit ID
  final String appOpenId;

  /// Rewarded ad unit ID
  final String rewardedId;

  const AppLovinConfig({
    required this.sdkKey,
    required this.bannerId,
    required this.interstitialId,
    required this.appOpenId,
    required this.rewardedId,
  });
}

/// AdMob ad unit IDs configuration.
class AdMobConfig {
  /// Banner ad unit ID
  final String bannerId;

  /// Interstitial ad unit ID
  final String interstitialId;

  /// App Open ad unit ID
  final String appOpenId;

  /// Rewarded ad unit ID (optional)
  final String rewardedId;

  /// Test device IDs (AdMob GAID hash list)
  final List<String> testDeviceIds;

  const AdMobConfig({
    required this.bannerId,
    required this.interstitialId,
    required this.appOpenId,
    this.rewardedId = '',
    this.testDeviceIds = const [],
  });
}

/// Master configuration for [AdManager].
///
/// Pass this to [AdManager.initialize] before [runApp].
class AdConfig {
  /// Which ad provider to use.
  final AdProvider provider;

  /// AppLovin MAX config. Required when [provider] == [AdProvider.appLovin].
  final AppLovinConfig? appLovin;

  /// AdMob config. Required when [provider] == [AdProvider.admob].
  final AdMobConfig? admob;

  /// GAID list of devices that should NEVER see ads (owners/testers).
  final List<String> vipDeviceGaids;

  /// Duration of the loading spinner shown before a fullscreen ad (ms).
  final int loadingBufferMs;

  /// Log level — verbose in debug, none in release.
  final AdLogLevel logLevel;

  /// Message shown in the top-center toast when a rewarded ad is unavailable.
  ///
  /// Defaults to English. Override with your own localized string.
  /// Example: `'ad_not_ready'.tr` (GetX) or `AppLocalizations.of(ctx)!.adNotReady`
  final String adNotReadyMessage;

  /// Text shown inside the loading spinner dialog before a fullscreen ad.
  ///
  /// Defaults to 'Loading…'. Override with a localized string.
  final String adLoadingMessage;

  const AdConfig({
    required this.provider,
    this.appLovin,
    this.admob,
    this.vipDeviceGaids = const [],
    this.loadingBufferMs = 1000,
    this.logLevel = AdLogLevel.verbose,
    this.adNotReadyMessage = 'Ad not ready — please wait and try again.',
    this.adLoadingMessage = 'Loading…',
  }) : assert(
          identical(provider, AdProvider.appLovin)
              ? appLovin != null
              : admob != null,
          'AppLovinConfig required for AppLovin provider, AdMobConfig required for AdMob provider',
        );

  /// Convenience getter
  bool get isAdMob => provider == AdProvider.admob;
}

/// Controls how much the SDK logs.
enum AdLogLevel {
  /// Log everything (recommended for debug)
  verbose,

  /// Log warnings and errors only
  warning,

  /// Suppress all SDK logs
  none,
}

// ═══════ Backward-compatible ad label constants ═══════
const String adPlsNoteEn =
    'Please note: this action may display app open ads.';
const String adPlsNoteVi =
    'Xin lưu ý: hành động này có thể hiển thị quảng cáo khi mở ứng dụng.';
const String adMayAppearEn = '(Ads may appear)';
const String adMayAppearVi = '(Có thể xuất hiện quảng cáo)';
