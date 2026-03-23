# applovin_admob_sdk

[![pub.dev](https://img.shields.io/pub/v/applovin_admob_sdk?label=pub.dev)](https://pub.dev/packages/applovin_admob_sdk)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.10.0-blue)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

**Dual-provider Flutter Ad SDK** — switch between AdMob and AppLovin MAX with a single line of config. Built-in anti-fraud safety layer, route-aware banner, animated top-center toast feedback, and VIP device bypass.

---

## Features

| Feature | Description |
|---|---|
| **Dual Provider** | Switch AdMob ↔ AppLovin with `AdProvider.admob` / `AdProvider.appLovin` |
| **Ad Types** | App Open, Banner, Interstitial, Rewarded |
| **Safety Layer** | Throttle, session/hourly/daily caps, CTR fraud detection, progressive cooldown |
| **RouteAware Banner** | Banner automatically pauses/resumes on navigation |
| **VIP Bypass** | Specific devices (by GAID) never see ads — for owners/testers |
| **Shimmer Placeholder** | Beautiful loading state while banner fills |
| **TopToast** | Animated glassmorphism toast at top-center — auto-shown when rewarded ad unavailable |
| **Localizable Strings** | `adNotReadyMessage` + `adLoadingMessage` in config — no hardcoded English |

---

## Installation

```yaml
dependencies:
  applovin_admob_sdk: ^1.0.2
```

### Android Setup (required)

**`android/app/src/main/AndroidManifest.xml`**:

```xml
<!-- AdMob -->
<meta-data
  android:name="com.google.android.gms.ads.APPLICATION_ID"
  android:value="ca-app-pub-xxxxxxxxxxxxxxxx~xxxxxxxxxx"/>

<!-- AppLovin -->
<meta-data
  android:name="applovin.sdk.key"
  android:value="YOUR_APPLOVIN_SDK_KEY"/>

<!-- GAID permission (required for VIP bypass + test device detection) -->
<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>
```

---

## Quick Start

### 1. Initialize in SplashScreen

```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

AdManager().initialize(
  config: AdConfig(
    provider: AdProvider.appLovin,          // or AdProvider.admob
    appLovin: AppLovinConfig(
      sdkKey: 'YOUR_86_CHAR_SDK_KEY',
      bannerId: 'YOUR_BANNER_ID',
      interstitialId: 'YOUR_INTER_ID',
      appOpenId: 'YOUR_APP_OPEN_ID',
      rewardedId: 'YOUR_REWARDED_ID',
    ),
    vipDeviceGaids: ['your-device-gaid'],   // never show ads on these devices
    // Localizable UI strings (override with your i18n solution):
    adNotReadyMessage: 'ad_not_ready'.tr,   // shown in TopToast when ad unavailable
    adLoadingMessage: 'loading'.tr,          // shown in AdLoadingDialog spinner
  ),
  onComplete: (success, gaid) {
    SafeLogger.d('App', 'Ad SDK ready. GAID: \$gaid');
  },
);
```

### 2. Add observers to your app

```dart
MaterialApp(
  navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
  // ...
)
```

### 3. Extend `AdScreen` on screens with ads

```dart
class HomeScreen extends AdScreen {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          buildBanner(),          // ← banner at top or bottom
          Expanded(child: /* ... your content */),
        ],
      ),
    );
  }
}
```

### 4. Show Interstitial

```dart
showInterstitialAd(onDone: (wasShown) {
  // navigate or do action here
});
```

### 5. Show Rewarded

```dart
showRewardedAd(onEarnedReward: (earned) {
  if (earned) unlockPremiumFeature();
  // else: SDK already showed TopToast "Ad not ready" automatically
});
```

### 6. Show App Open (splash)

```dart
AdManager().showAppOpenAd(
  bypassSafety: true,     // true on splash, false on resume
  onAdDismiss: (shown) => navigateToHome(),
);
```

### 7. TopToast (manual use)

```dart
TopToast.show(
  context,
  icon: Icons.info_outline,
  message: 'Your message here',
  iconColor: Colors.blue,     // optional, default amber
);
```

---

## Advanced Configuration

### AdMob Provider

```dart
AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: kDebugMode
      ? 'ca-app-pub-3940256099942544/6300978111'
      : 'ca-app-pub-xxxxxxxx/xxxxxxxx',
    interstitialId: '...',
    appOpenId: '...',
    rewardedId: '...',
    testDeviceIds: ['YOUR_TEST_DEVICE_HASH'],
  ),
)
```

### Custom Safety Parameters

```dart
// AdSafetyParams currently use defaults — customizable via AdSafetyConfig.init()
```

---

## License

MIT © 2026 — see [LICENSE](LICENSE)
