# applovin_admob_sdk

[![pub.dev](https://img.shields.io/pub/v/applovin_admob_sdk?label=pub.dev)](https://pub.dev/packages/applovin_admob_sdk)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.10.0-blue)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

**Dual-provider Flutter Ad SDK** — AdMob + AppLovin MAX behind a single API.
Adapter pattern, state-machine, VIP system with Cupertino dialog,
GDPR/COPPA/CCPA flags, exponential backoff, revenue events stream,
debug overlay.

---

## EN: Quick start (5 steps)

### 1. Add dependency

```yaml
dependencies:
  applovin_admob_sdk: ^2.0.0
```

### 2. Native config

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>

<application>
  <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"
             android:value="ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY"/>
  <meta-data android:name="applovin.sdk.key" android:value="YOUR_86_CHAR_KEY"/>
</application>
```

`android/app/build.gradle.kts` → `minSdk = 21` (AdMob requirement).

**iOS** (`ios/Runner/Info.plist`):

```xml
<key>GADApplicationIdentifier</key><string>ca-app-pub-XXX~YYY</string>
<key>AppLovinSdkKey</key><string>YOUR_86_CHAR_KEY</string>
<key>NSUserTrackingUsageDescription</key>
<string>This identifier is used to deliver personalised ads.</string>
<key>SKAdNetworkItems</key><array>...</array>
```

`ios/Podfile` → `platform :ios, '12.0'`.

### 3. Initialise (in `SplashScreen`, NOT `main`)

```dart
final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AdManager().setNavigatorKey(navigatorKey);  // BEFORE runApp
  runApp(MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    home: const SplashScreen(),
  ));
}
```

In `SplashScreen.initState`:

```dart
AdManager().markSplashActive();
AdManager().incrementSplashCount();

// Register listener BEFORE calling initialize()
SimpleEventBus().listen((e) => e.value ? showAppOpen() : navigateHome());

WidgetsBinding.instance.addPostFrameCallback((_) {
  AdManager().initialize(
    config: AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(...),
      admob:    AdMobConfig(...),
      logLevel: AdLogLevel.warning,
      onLog: (lvl, tag, msg) => Sentry.captureMessage('[$tag] $msg'),
      vipKeyValidator: (key) => myServer.verifyVip(key),
    ),
    onComplete: (success, gaid) {},
  );
});
```

### 4. Show ads

Make any screen extend `AdScreen` to gain `buildBanner` / `showInterstitialAd` / `showRewardedAd`:

```dart
class HomeScreen extends AdScreen {
  @override State createState() => _S();
}
class _S extends AdScreenState<HomeScreen> {
  Widget build(_) => Column(children: [
    buildBanner(),
    FilledButton(
      onPressed: () => showInterstitialAd(onDone: (_) {}),
      child: Text('Show ad'),
    ),
  ]);
}
```

### 5. Compliance (recommended)

```dart
// After your UMP form (Google) or your own consent UI:
await AdManager().setConsent(AdConsent(
  hasUserConsent: userAcceptedGdpr,
  isAgeRestrictedUser: false,  // true = COPPA mode
  doNotSell: false,            // true = CCPA opt-out
));
```

#### Privacy / Compliance checklist

- [ ] `app-ads.txt` placed at your domain root.
- [ ] Privacy Policy URL declared in App Store / Play Store listing.
- [ ] iOS ATT prompt shown via `app_tracking_transparency` **before** `AdManager().initialize`.
- [ ] UMP consent form shown via `umpsdk` — call `setConsent(...)` after.
- [ ] If app targets children, set `isAgeRestrictedUser: true`.

---

## VI: Hướng dẫn nhanh (5 bước)

### 1. Thêm dependency

```yaml
dependencies:
  applovin_admob_sdk: ^2.0.0
```

### 2. Cấu hình native

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>

<application>
  <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"
             android:value="ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY"/>
  <meta-data android:name="applovin.sdk.key" android:value="KEY_86_KÝ_TỰ"/>
</application>
```

`android/app/build.gradle.kts` → `minSdk = 21`.

**iOS** (`ios/Runner/Info.plist`):

```xml
<key>GADApplicationIdentifier</key><string>ca-app-pub-XXX~YYY</string>
<key>AppLovinSdkKey</key><string>KEY_86_KÝ_TỰ</string>
<key>NSUserTrackingUsageDescription</key>
<string>ID này được dùng để hiển thị quảng cáo phù hợp hơn.</string>
<key>SKAdNetworkItems</key><array>...</array>
```

`ios/Podfile` → `platform :ios, '12.0'`.

### 3. Khởi tạo (trong `SplashScreen`, KHÔNG đặt trong `main`)

```dart
final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AdManager().setNavigatorKey(navigatorKey);  // BẮT BUỘC trước runApp
  runApp(MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    home: const SplashScreen(),
  ));
}
```

Trong `SplashScreen.initState`:

```dart
AdManager().markSplashActive();
AdManager().incrementSplashCount();

// ⚠️ Đăng ký listener TRƯỚC khi gọi initialize() —
// EventBus chỉ phát đến listener đã đăng ký từ trước.
SimpleEventBus().listen((e) => e.value ? showAppOpen() : navigateHome());

WidgetsBinding.instance.addPostFrameCallback((_) {
  AdManager().initialize(
    config: AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(...),
      admob:    AdMobConfig(...),
      logLevel: AdLogLevel.warning,
      onLog: (lvl, tag, msg) => print('[$tag] $msg'),
      vipKeyValidator: (key) => myServer.verifyVip(key),
    ),
    onComplete: (success, gaid) {},
  );
});
```

### 4. Hiển thị ad

Cho màn hình kế thừa `AdScreen` để có sẵn `buildBanner` / `showInterstitialAd` / `showRewardedAd`:

```dart
class HomeScreen extends AdScreen {
  @override State createState() => _S();
}
class _S extends AdScreenState<HomeScreen> {
  Widget build(_) => Column(children: [
    buildBanner(),
    FilledButton(
      onPressed: () => showInterstitialAd(onDone: (_) {}),
      child: Text('Hiện ad'),
    ),
  ]);
}
```

### 5. Tuân thủ pháp lý (khuyên dùng)

```dart
// Sau khi user nhấn ACCEPT/DECLINE ở form UMP:
await AdManager().setConsent(AdConsent(
  hasUserConsent: userAcceptedGdpr,
  isAgeRestrictedUser: false,  // true = app dành cho trẻ em (COPPA)
  doNotSell: false,            // true = user California opt-out (CCPA)
));
```

#### Checklist tuân thủ

- [ ] `app-ads.txt` đặt ở root domain của bạn.
- [ ] Privacy Policy URL khai báo trong App Store / Play Store listing.
- [ ] iOS ATT prompt: gọi `app_tracking_transparency` **trước** `AdManager().initialize`.
- [ ] UMP consent form: dùng package `umpsdk`, sau đó gọi `setConsent(...)`.
- [ ] App cho trẻ em → set `isAgeRestrictedUser: true`.

---

## Features (2.0)

| Feature | Description |
|---|---|
| **Adapter pattern** | `AdMobAdapter` + `AppLovinAdapter` behind `AdProviderAdapter`. One config flag swaps providers. |
| **State machine** | `AdSlot` per ad type — replaces ~14 bool flags. Eliminates whole classes of races. |
| **VIP system** | `redeemVip(context, key, duration)` with Cupertino dialog. Persistent expiry, latest-wins conflict, auto-migrate from 1.x GAID list. |
| **Compliance** | `AdConsent` flags forwarded to both providers. Conservative default = non-personalised. |
| **Logging** | 4 levels + lazy interpolation + tag filter + `onLog` sink (Crashlytics / Sentry). |
| **Safety** | 12-layer anti-fraud (caps / throttle / CTR / progressive cooldown). All knobs configurable; `dryRun` for QA. |
| **Events stream** | `Stream<AdEvent>` — `AdLoadEvent`, `AdShowEvent`, `AdRevenueEvent`, …. Pipe into Firebase / AppsFlyer for LTV tracking. |
| **Exponential backoff** | Replaces the legacy fixed 15-min cooldown. |
| **Splash budget** | SDK auto-fires `markSplashInactive` after `splashMaxDuration` (default 8 s). |
| **Memory pressure** | Auto-drops cached fullscreen ads on `didHaveMemoryPressure`. |
| **Debug overlay** | `DebugAdOverlay` — floating panel showing realtime state (`kDebugMode` only). |
| **Revenue panel** | `RevenuePanel` widget reads the events stream. |

---

## Migration from 1.x

See `MIGRATION.md` for the step-by-step guide.

## Demo

`example/lib/` ships with **11 demo pages** — one per feature. Drop your AppLovin keys into `example/lib/demo_config.dart` (or run as-is using AdMob test IDs) and `flutter run`.

## License

MIT.
