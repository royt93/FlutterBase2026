## 1.0.4

- Fixed double `loadAppOpenAd` in-flight guard for **AppLovin** provider — `_isAppOpenLoading` is now set/reset in `_loadAppOpenAdAppLovin` and its loaded/failed callbacks, preventing duplicate requests and callback overwrites that broke the splash App Open flow
- Fixed hard cap timer not being cancelled before `showAppOpenAd` is called in splash — prevents force-navigation while an ad is actively displaying (example + WiFi splash screens)


- Replaced all `debugPrint` in `AdScreenRouteLogger` with `SafeLogger.d` — consistent logging across the entire SDK
- Bumped dependencies: `google_mobile_ads: ^7.0.0`, `shared_preferences: ^2.5.4`, `connection_notifier: ^3.0.0`, `flutter_lints: ^6.0.0`


- Renamed package from `ad_sdk` to `applovin_admob_sdk`
- `AdConfig` now supports `adNotReadyMessage` and `adLoadingMessage` for localizable UI strings
- `showRewardedAd` auto-shows `TopToast` with `adNotReadyMessage` when no ad is available — callers no longer need to show their own feedback
- `AdLoadingDialog` uses `adLoadingMessage` from config instead of hardcoded `'Loading...'`
- `AdManager` exposes public `config` getter

## 1.0.1

- Added `TopToast` — animated, glassmorphism top-center toast widget (overlay-based, no Scaffold needed)
- `showRewardedAd`: changed to hard gate — `onEarnedReward(false)` when ad unavailable (caller shows user feedback)
- Fixed `_hasPlaceholderIds()` logic bug in example app splash screen

## 1.0.0

- Initial release
- Dual-provider support: AdMob (google_mobile_ads) and AppLovin MAX (applovin_max)
- Ad types: App Open, Banner, Interstitial, Rewarded
- 12-measure AdSafety layer: throttle, session/hourly/daily caps, CTR fraud, progressive cooldown
- RouteAware banner with auto pause/resume on navigation
- VIP device bypass via GAID list
- Shimmer loading placeholder for banner
- AdLoadingDialog buffer before fullscreen ads
- Provider-agnostic AdScreen base class (no external state manager required)
