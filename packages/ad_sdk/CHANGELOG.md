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
