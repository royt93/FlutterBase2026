# applovin_admob_sdk

[![pub.dev](https://img.shields.io/pub/v/applovin_admob_sdk?label=pub.dev)](https://pub.dev/packages/applovin_admob_sdk)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.10.0-blue)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

**Dual-provider Flutter Ad SDK** — switch between AdMob and AppLovin MAX with a single line of config.  
Built-in anti-fraud safety layer, route-aware banner lifecycle, animated top-center toast, and VIP device bypass.

---

## 🎯 Features

| Feature | Description |
|---|---|
| **Dual Provider** | Switch AdMob ↔ AppLovin with `AdProvider.admob` / `AdProvider.appLovin` |
| **Ad Types** | App Open, Banner, Interstitial, Rewarded |
| **Safety Layer** | Throttle, session/hourly/daily caps, CTR fraud detection, progressive cooldown |
| **RouteAware Banner** | Banner automatically pauses/resumes on navigation — no manual code needed |
| **VIP Bypass** | Specific devices (by GAID) never see ads — perfect for owners/testers |
| **Shimmer Placeholder** | Beautiful skeleton loading state while banner fills |
| **TopToast** | Animated glassmorphism toast at top-center — auto-shown when rewarded ad unavailable |
| **Localizable Strings** | `adNotReadyMessage` + `adLoadingMessage` configurable — no hardcoded strings |

---

## 📋 Table of Contents

1. [Prerequisites](#-prerequisites)
2. [Installation](#-installation)
3. [Android Setup](#-android-setup)
4. [iOS Setup](#-ios-setup)
5. [AdMob Setup](#-admob-setup)
6. [AppLovin Setup](#-applovin-setup)
7. [Integration Guide (Step-by-Step)](#-integration-guide-step-by-step)
8. [Ad Types Reference](#-ad-types-reference)
9. [AdConfig Reference](#-adconfig-reference)
10. [Safety Layer](#-safety-layer)
11. [VIP Bypass](#-vip-bypass)
12. [TopToast](#-toptoast)
13. [Troubleshooting](#-troubleshooting)

---

## 🔧 Prerequisites

- Flutter ≥ 3.10.0
- Dart ≥ 3.0.0
- An **AdMob account** at [admob.google.com](https://admob.google.com) and/or  
  an **AppLovin account** at [applovin.com](https://www.applovin.com)
- Android minSdk ≥ 21
- iOS deployment target ≥ 12.0

---

## 📦 Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  applovin_admob_sdk: ^1.0.13
```

Then run:

```bash
flutter pub get
```

> **If using AppLovin MAX**, you also need the mediation plugin at the app level  
> (cannot be declared inside a sub-package):
>
> ```yaml
> dependencies:
>   gma_mediation_applovin: ^1.0.0   # required for AppLovin + AdMob mediation
> ```

---

## 🤖 Android Setup

### 1. AndroidManifest.xml

Open `android/app/src/main/AndroidManifest.xml` and add inside `<application>`:

```xml
<!-- ✅ Required for AdMob — get your App ID from admob.google.com -->
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-xxxxxxxxxxxxxxxx~xxxxxxxxxx"/>

<!-- ✅ Required for AppLovin — get your SDK Key from applovin.com/account -->
<meta-data
    android:name="applovin.sdk.key"
    android:value="YOUR_86_CHARACTER_SDK_KEY"/>
```

Also add `<uses-permission>` **before** `<application>`:

```xml
<!-- ✅ Required: GAID permission for VIP bypass + test device detection -->
<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>
```

### 2. build.gradle minSdk

Open `android/app/build.gradle` and ensure:

```groovy
android {
    defaultConfig {
        minSdk 21   // must be ≥ 21 for Google Mobile Ads
    }
}
```

---

## 🍎 iOS Setup

### 1. Info.plist

Open `ios/Runner/Info.plist` and add:

```xml
<!-- ✅ Required for AdMob -->
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-xxxxxxxxxxxxxxxx~xxxxxxxxxx</string>

<!-- ✅ Required for iOS 14+ tracking -->
<key>NSUserTrackingUsageDescription</key>
<string>This identifier will be used to deliver personalized ads to you.</string>

<!-- ✅ Required for AppLovin -->
<key>AppLovinSdkKey</key>
<string>YOUR_86_CHARACTER_SDK_KEY</string>
```

### 2. Podfile

Open `ios/Podfile` and ensure:

```ruby
platform :ios, '12.0'   # must be ≥ 12.0
```

Then run:

```bash
cd ios && pod install
```

---

## 📱 AdMob Setup

1. Go to [admob.google.com](https://admob.google.com) → **Apps** → **Add App**
2. Create ad units for each type:
   - Banner: `ca-app-pub-xxxxxxxx/xxxxxxxxxx`
   - Interstitial: `ca-app-pub-xxxxxxxx/xxxxxxxxxx`
   - App Open: `ca-app-pub-xxxxxxxx/xxxxxxxxxx`
   - Rewarded: `ca-app-pub-xxxxxxxx/xxxxxxxxxx`

> **Test IDs** (use these during development, never in production):
> ```
> App ID:           ca-app-pub-3940256099942544~3347511713
> Banner:           ca-app-pub-3940256099942544/6300978111
> Interstitial:     ca-app-pub-3940256099942544/1033173712
> App Open:         ca-app-pub-3940256099942544/9257395921
> Rewarded:         ca-app-pub-3940256099942544/5224354917
> ```

---

## 🔑 AppLovin Setup

1. Go to [dash.applovin.com](https://dash.applovin.com) → **Account** → copy **SDK Key** (86 chars)
2. Go to **MAX** → **Mediation** → **Ad Units** → **New Ad Unit** for each type:
   - Banner, Interstitial, App Open, Rewarded (each is a 16-character ID)

> **⚠️ Important:** AppLovin has **NO universal test IDs** unlike AdMob.  
> You must use **real ad unit IDs** from your dashboard.  
> To see test ads, register your device as a test device using your GAID  
> (the SDK does this automatically in debug mode — see logs for GAID).

---

## 🚀 Integration Guide (Step-by-Step)

This guide walks you through integrating the SDK from scratch.  
Follow **every step** in order.

---

### Step 1 — Add the package

`pubspec.yaml`:
```yaml
dependencies:
  applovin_admob_sdk: ^1.0.13
  gma_mediation_applovin: ^1.0.0   # only if using AppLovin
```

```bash
flutter pub get
```

---

### Step 2 — Register `navigatorKey` and `navigatorObservers`

The SDK needs:
1. A **navigator key** — so it can show loading dialogs from lifecycle callbacks (e.g. App Open on resume)
2. **Route observers** — to manage the banner lifecycle (pause/resume automatically)

```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

// ✅ Create a global navigator key
final navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ✅ Register navigator key BEFORE runApp
  AdManager().setNavigatorKey(navigatorKey);
  runApp(const MyApp());
}

// In your MaterialApp:
MaterialApp(
  navigatorKey: navigatorKey,    // ✅ REQUIRED — pass key to MaterialApp
  navigatorObservers: [
    adRouteObserver,              // manages RouteAware banner
    AdScreenRouteLogger(),        // logs route changes for debugging
  ],
  home: const SplashScreen(),
)
```

> **Why navigator key?** Without it, the App Open ad shown when returning from background won't display a loading dialog (1s spinner) before showing. The SDK needs the navigator context to show dialogs from lifecycle observers.
>
> **Why route observers?** Without `adRouteObserver`, the banner will not pause when another screen pushes on top, causing double-billing.

---

### Step 3 — Create your SplashScreen

The SDK **must be initialized in SplashScreen**, not in `main()`. This ensures the EventBus notifies the listener only after it is registered.

```dart
import 'dart:async';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _hasNavigated = false;
  void Function(BoolEvent)? _eventListener;
  Timer? _hardCapTimer;

  @override
  void initState() {
    super.initState();
    AdManager().markSplashActive();        // tell SDK splash is shown
    AdManager().incrementSplashCount();    // track how many times splash showed

    // If this is not the first time (e.g. app re-opened), skip ads
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigateHome());
      return;
    }

    // Hard cap: force navigate after 8 seconds even if ad didn't load
    _hardCapTimer = Timer(const Duration(seconds: 8), () {
      SafeLogger.d('Splash', '⏰ Hard cap → force navigate');
      _navigateHome();
    });

    // ✅ Register EventBus listener BEFORE calling initialize()
    _eventListener = (event) {
      if (event.value) {
        _loadAndShowAppOpenAd();
      } else {
        _navigateHome(); // init failed
      }
    };
    SimpleEventBus().listen(_eventListener!);

    // ✅ Initialize AdManager inside postFrameCallback
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().initialize(
        config: AdConfig(
          // ← change this to AdProvider.admob for AdMob
          provider: AdProvider.appLovin,
          admob: AdMobConfig(
            bannerId: 'ca-app-pub-3940256099942544/6300978111',
            interstitialId: 'ca-app-pub-3940256099942544/1033173712',
            appOpenId: 'ca-app-pub-3940256099942544/9257395921',
            rewardedId: 'ca-app-pub-3940256099942544/5224354917',
          ),
          appLovin: AppLovinConfig(
            sdkKey: 'YOUR_86_CHAR_SDK_KEY',
            bannerId: 'YOUR_BANNER_ID',
            interstitialId: 'YOUR_INTER_ID',
            appOpenId: 'YOUR_APP_OPEN_ID',
            rewardedId: 'YOUR_REWARDED_ID',
          ),
          vipDeviceGaids: [],            // add your GAID here to skip ads on your device
          loadingBufferMs: 1000,         // ms to wait after ad loads before showing
          adNotReadyMessage: 'Ad not ready — please try again later.',
          adLoadingMessage: 'Loading…',
        ),
        onComplete: (success, gaid) {
          SafeLogger.d('Splash', 'SDK ready. GAID: $gaid');
        },
      );
    });
  }

  void _loadAndShowAppOpenAd() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_hasNavigated) return;
      if (loaded) {
        if (!mounted) { _navigateHome(); return; }
        AdLoadingDialog.showAdBuffer(context, onComplete: () {
          if (!mounted) { _navigateHome(); return; }
          // ✅ Cancel hard cap timer BEFORE showing ad
          _hardCapTimer?.cancel();
          _hardCapTimer = null;
          AdManager().showAppOpenAd(
            bypassSafety: true,          // always bypass on splash
            onAdDismiss: (_) => _navigateHome(),
          );
        });
      } else {
        _navigateHome();
      }
    });
  }

  void _navigateHome() {
    if (_hasNavigated) return;
    _hasNavigated = true;
    _hardCapTimer?.cancel();
    _hardCapTimer = null;
    if (_eventListener != null) {
      SimpleEventBus().remove(_eventListener!);
      _eventListener = null;
    }
    AdManager().markSplashInactive();    // ✅ always call this exactly once
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void dispose() {
    _hardCapTimer?.cancel();
    if (_eventListener != null) {
      SimpleEventBus().remove(_eventListener!);
      _eventListener = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
```

---

### Step 4 — Extend `AdScreen` on screens that show ads

Instead of `StatefulWidget`, extend `AdScreen`. This gives you `buildBanner()`, `showInterstitialAd()`, and `showRewardedAd()` for free.

```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

class HomeScreen extends AdScreen {         // ← extend AdScreen
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {   // ← extend AdScreenState
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          buildBanner(),                    // ← add banner (top or bottom)
          Expanded(
            child: Center(
              child: ElevatedButton(
                onPressed: () {
                  showInterstitialAd(onDone: (shown) {
                    // called after ad finishes (shown or skipped)
                  });
                },
                child: const Text('Show Interstitial'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

---

### Step 5 — Show Rewarded Ad

```dart
showRewardedAd(
  onEarnedReward: (earned) {
    if (earned) {
      // ✅ User watched the full ad — grant the reward
      giveUserCoins(10);
    }
    // If not earned, SDK automatically shows "Ad not ready" TopToast
  },
);
```

---

### Step 6 — Show Interstitial Ad

```dart
showInterstitialAd(
  onDone: (wasShown) {
    // ✅ This is always called, whether ad showed or not
    // Do your navigation or next action here
    Navigator.push(context, MaterialPageRoute(builder: (_) => NextScreen()));
  },
);
```

> **Tip:** Always put your navigation **inside** `onDone`, not before `showInterstitialAd`. This ensures navigation happens after the ad, not during.

---

### Step 7 — Switch Provider

To switch from AppLovin to AdMob (or vice versa), change only **one line**:

```dart
AdConfig(
  provider: AdProvider.admob,    // ← change here: admob or appLovin
  admob: AdMobConfig(...),       // AdMob config (used when provider = admob)
  appLovin: AppLovinConfig(...), // AppLovin config (used when provider = appLovin)
)
```

Both configs can exist simultaneously. Only the selected provider is used.

---

## 📚 Ad Types Reference

### Banner Ad

- Added automatically via `buildBanner()` inside `AdScreenState`
- Pauses when another screen pushes on top (via `RouteAware`)
- Resumes when returning to the screen
- Auto-refreshes every ~15 seconds (managed by network)
- Shows shimmer loading state while filling

```dart
// Place at top or bottom of your Scaffold body
buildBanner()
```

### Interstitial Ad

- Full-screen between user actions (e.g. before navigation)
- Built-in 30-second throttle between shows
- Preloaded automatically on screen init

```dart
showInterstitialAd(onDone: (wasShown) { /* navigate here */ });
```

### Rewarded Ad

- Full-screen opt-in for users to earn rewards
- Built-in throttle (same as interstitial)
- TopToast automatically shown if ad not ready

```dart
showRewardedAd(onEarnedReward: (earned) { if (earned) grantReward(); });
```

### App Open Ad

- Shown on cold start (splash) and when app returns from background
- On splash: call with `bypassSafety: true`
- On resume: SDK handles automatically via `AppLifecycleState`
- **Loading dialog** (1s spinner) is shown automatically before the ad — requires `setNavigatorKey()` in `main()`

```dart
// On splash only — SDK handles resume automatically
AdManager().showAppOpenAd(
  bypassSafety: true,
  onAdDismiss: (_) => navigateToHome(),
);
```

---

## ⚙️ AdConfig Reference

```dart
AdConfig(
  // ── Required ──────────────────────────────────────
  provider: AdProvider.appLovin,   // or AdProvider.admob

  // ── Provider configs (include both — switch via 'provider' field) ──
  admob: AdMobConfig(
    bannerId: '...',
    interstitialId: '...',
    appOpenId: '...',
    rewardedId: '...',
    testDeviceIds: ['HASH'],       // optional: AdMob test device hash
  ),
  appLovin: AppLovinConfig(
    sdkKey: '...',                // 86-character SDK key
    bannerId: '...',              // 16-character ad unit ID
    interstitialId: '...',
    appOpenId: '...',
    rewardedId: '...',
  ),

  // ── Optional ──────────────────────────────────────
  vipDeviceGaids: ['gaid-1'],     // these devices never see ads
  loadingBufferMs: 1000,          // delay before showing ad (ms), default 1000
  adNotReadyMessage: 'Ad not ready — please try again later.',
  adLoadingMessage: 'Loading…',
)
```

---

## 🛡️ Safety Layer

The SDK includes a built-in anti-fraud safety layer that prevents ad spam:

| Limit | Default | Description |
|---|---|---|
| **Daily cap** | 5 ads/day | Total fullscreen ads per day |
| **Hourly cap** | 3 ads/hour | Fullscreen ads per hour |
| **Session cap** | 6 ads/session | Fullscreen ads per app open |
| **Throttle** | 30s | Minimum gap between fullscreen ads |
| **CTR cap** | 3 clicks/min | Suspicious click rate detection |
| **Cooldown** | Progressive | Error backoff to prevent hammering network |

Safety is applied automatically. You do not need to configure it unless you want to customize limits via `AdSafetyConfig`.

---

## 👑 VIP Bypass

Add device GAIDs to skip ads for app owners and internal testers:

```dart
AdConfig(
  vipDeviceGaids: [
    'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',  // your device GAID
  ],
  // ...
)
```

**How to find your GAID:** Run the example app in debug mode. The GAID is logged at init:
```
[AdManager] ###init GAID: be39dfe0-67f5-4da4-afb3-8407cd481df4
```

> **Note:** In debug builds, VIP member list is not enforced  
> (`###init Debug mode, skip adding VIP members`).  
> This is intentional — it prevents accidental production GAID exposure.

---

## 🍞 TopToast

A glassmorphism animated toast that slides in from the top of the screen.  
Used automatically when a rewarded ad is not ready.

**Manual usage:**

```dart
TopToast.show(
  context,
  icon: Icons.info_outline,       // optional, default: warning icon
  message: 'Your message here',
  iconColor: Colors.blue,         // optional, default: amber
);
```

---

## 🔍 Troubleshooting

### Ads not showing

1. Check `AndroidManifest.xml` has `APPLICATION_ID` meta-data
2. Check your ad unit IDs are correct (not placeholder `YOUR_*`)
3. Check network connectivity
4. Wait — new ad units take up to 24h to activate on AdMob
5. Enable logging and look for `❌ Failed:` or `🛡️ blocked:` in logs

### Loading dialog stuck on screen (never dismisses)

**Root cause:** The loading dialog shown before every fullscreen ad (inter / rewarded / app open) can get stuck if the parent screen is disposed while the buffer timer is running.

**Flow that triggers the bug (pre-1.0.8):**
```
showAdBuffer() called → dialog shown → await 1000ms
  → screen disposed during 1s wait (user navigates back fast)
  → context.mounted == false → pop() was skipped
  → dialog stays on screen forever, nobody dismisses it
```

**Fix (1.0.8+):**  `NavigatorState` is now captured **before** the async delay. Since `NavigatorState` is owned by the root navigator (not the screen), it outlives any screen disposal and can always pop the dialog.

```dart
// ✅ Correct — navigator captured before any await
final navigator = Navigator.of(context, rootNavigator: true);
await Future.delayed(duration);
navigator.pop(); // always works, even if screen is disposed
```

### Hard cap timer fires before App Open Ad shows

Ensure you call `AdManager().markSplashActive()` and `markSplashInactive()` in your splash screen, and that `_hardCapTimer?.cancel()` is called **before** `showAppOpenAd()`.

### Banner not showing

1. `adRouteObserver` must be in `navigatorObservers`
2. Your screen must extend `AdScreen` + `AdScreenState`
3. Call `buildBanner()` inside your widget tree (not conditionally)

### AppLovin ads not loading

1. SDK Key must be exactly 86 characters — check `dash.applovin.com/o/account`
2. Ad Unit IDs must be exactly 16 characters — check `dash.applovin.com/o/mediation/ad_units`
3. Register your test device in AppLovin dashboard or rely on debug auto-registration

### "Ad not ready" toast appears every time

The safety throttle is active. Default is 30 seconds between ads. Wait and try again.

### Rewarded ad watched but reward not granted

Check that `onEarnedReward(true)` is being called — look for log:
```
[AdManager] 🏆 [AppLovin] Rewarded Ad Earned Reward
```
If missing, the user skipped the ad (did not watch fully). The SDK calls `onEarnedReward(false)` automatically in this case.

---

## 📄 License

MIT © 2026 — see [LICENSE](LICENSE)
