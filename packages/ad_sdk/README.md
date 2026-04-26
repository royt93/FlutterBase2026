# applovin_admob_sdk

[![pub.dev](https://img.shields.io/pub/v/applovin_admob_sdk?label=pub.dev)](https://pub.dev/packages/applovin_admob_sdk)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.27.0-blue)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

**SDK quảng cáo Flutter dùng cả AdMob lẫn AppLovin MAX qua một API duy nhất.**

✨ Đổi provider chỉ bằng 1 dòng code · 🎯 VIP system tự động · 🛡️ Anti-fraud 12 lớp · 🍎 Cupertino consent dialog đẹp · 💰 Revenue events stream · 🐛 Debug overlay realtime

---

## 🇻🇳 Hướng dẫn cho người mới (copy-paste 6 bước)

> Anh em không cần biết gì về Flutter / AdMob / AppLovin. Làm đúng 6 bước này là chạy được.

### Bước 1️⃣ — Thêm vào `pubspec.yaml`

Mở file `pubspec.yaml` ở thư mục gốc app, dán đoạn sau vào mục `dependencies:`:

```yaml
dependencies:
  applovin_admob_sdk: ^1.0.15
  gma_mediation_applovin:   # bắt buộc nếu dùng AdMob mediation, không thì xóa dòng này
```

Chạy lệnh này trong terminal:

```bash
flutter pub get
```

### Bước 2️⃣ — Cấu hình Android (file `android/app/src/main/AndroidManifest.xml`)

Mở file `AndroidManifest.xml`, **dán** vào trong thẻ `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>
```

**Dán** vào trong thẻ `<application>` (thay 2 KEY bằng key thật từ AdMob/AppLovin dashboard):

```xml
<!-- AdMob App ID — lấy từ admob.google.com → Settings → App ID -->
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-3940256099942544~3347511713"/>

<!-- AppLovin SDK Key (86 ký tự) — lấy từ dash.applovin.com → Account → Keys -->
<meta-data
    android:name="applovin.sdk.key"
    android:value="DAN_KEY_86_KY_TU_CUA_BAN_VAO_DAY"/>
```

> 💡 Nếu chưa có AdMob/AppLovin account, dùng key test ở trên (`ca-app-pub-3940256099942544~3347511713` là test app ID công khai của Google).

⚠️ **KHÔNG ĐƯỢC** thêm `android:taskAffinity=""` vào MainActivity. Nếu Flutter create template tự thêm, hãy **xóa nó đi** — gây crash khi user background app trong lúc xem ad.

Mở file `android/app/build.gradle` hoặc `build.gradle.kts`, sửa:

```kotlin
defaultConfig {
    minSdk = 21      // bắt buộc, AdMob yêu cầu
    // ...
}
```

### Bước 3️⃣ — Cấu hình iOS (file `ios/Runner/Info.plist`)

Mở file `Info.plist`, **dán** vào trong thẻ `<dict>` ngoài cùng:

```xml
<!-- AdMob App ID -->
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-3940256099942544~1458002511</string>

<!-- AppLovin SDK Key (giống bên Android) -->
<key>AppLovinSdkKey</key>
<string>DAN_KEY_86_KY_TU_CUA_BAN_VAO_DAY</string>

<!-- iOS bắt buộc — text này hiện khi iOS hỏi quyền tracking -->
<key>NSUserTrackingUsageDescription</key>
<string>App dùng ID này để hiển thị quảng cáo phù hợp hơn với bạn.</string>

<!-- SKAdNetworkItems — copy nguyên đoạn dài này từ Google AdMob docs -->
<!-- https://developers.google.com/admob/ios/ios14#skadnetwork -->
```

Mở `ios/Podfile`, sửa dòng `platform`:

```ruby
platform :ios, '12.0'
```

Chạy:

```bash
cd ios && pod install && cd ..
```

### Bước 4️⃣ — Code Dart: 2 file

**File 1: `lib/main.dart`** — copy/paste y nguyên:

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // ⚠️ BẮT BUỘC: setNavigatorKey trước runApp để SDK show được consent dialog
  AdManager().setNavigatorKey(navigatorKey);
  runApp(MaterialApp(
    navigatorKey: navigatorKey,
    // ⚠️ BẮT BUỘC: 2 observers để banner pause/resume tự động
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    home: const SplashScreen(),
  ));
}
```

**File 2: `lib/splash_screen.dart`** — copy/paste y nguyên (chỉ sửa 5 ID đánh dấu `// TODO`):

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'main.dart';                  // để dùng navigatorKey
import 'home_screen.dart';            // màn hình chính của bạn

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _hardCap;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }

    _hardCap = Timer(const Duration(seconds: 30), _goHome);

    // ⚠️ BẮT BUỘC: đăng ký listener TRƯỚC khi gọi initialize()
    SimpleEventBus().listen((e) => e.value ? _showAppOpen() : _goHome());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().initialize(
        config: AdConfig(
          provider: AdProvider.appLovin,    // hoặc AdProvider.admob
          // TODO: đổi 4 ID + sdkKey bằng giá trị thật của bạn từ dashboard
          appLovin: const AppLovinConfig(
            sdkKey: 'DAN_KEY_86_KY_TU_VAO_DAY',
            bannerId: 'banner_unit_id',
            interstitialId: 'inter_unit_id',
            appOpenId: 'appopen_unit_id',
            rewardedId: 'rewarded_unit_id',
          ),
          // TODO: AdMob ID test mặc định bên dưới có thể giữ để test, prod thay bằng ID thật
          admob: const AdMobConfig(
            bannerId: 'ca-app-pub-3940256099942544/6300978111',
            interstitialId: 'ca-app-pub-3940256099942544/1033173712',
            appOpenId: 'ca-app-pub-3940256099942544/9257395921',
            rewardedId: 'ca-app-pub-3940256099942544/5224354917',
          ),
          // Dialog tiếng Việt — hoặc dùng const ConsentDialogStrings() cho tiếng Anh
          consentDialogStrings: ConsentDialogStrings.vi,
        ),
        onComplete: (success, gaid) {},
      );
    });
  }

  void _showAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated) return;
      if (!loaded || !mounted) { _goHome(); return; }
      AdLoadingDialog.showAdBuffer(context, onComplete: () {
        if (!mounted) { _goHome(); return; }
        _hardCap?.cancel();
        AdManager().showAppOpenAd(
          bypassSafety: true,
          onAdDismiss: (_) => _goHome(),
        );
      });
    });
  }

  void _goHome() {
    if (_navigated) return;
    _navigated = true;
    _hardCap?.cancel();
    AdManager().markSplashInactive();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void dispose() { _hardCap?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.deepPurple,
    body: Center(child: CircularProgressIndicator(color: Colors.white)),
  );
}
```

### Bước 5️⃣ — Hiển thị ad ở màn hình bất kỳ

**File `lib/home_screen.dart`** — copy/paste:

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class HomeScreen extends AdScreen {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My App')),
    body: Column(children: [
      // BANNER — tự load, tự refresh, tự pause khi navigate, tự VIP-skip
      buildBanner(),

      // INTERSTITIAL
      FilledButton(
        onPressed: () => showInterstitialAd(onDone: (shown) {
          if (shown) print('Inter shown');
        }),
        child: const Text('Show interstitial'),
      ),

      // REWARDED
      FilledButton(
        onPressed: () => showRewardedAd(
          onEarnedReward: (earned) {
            if (earned) print('+10 coins');
          },
        ),
        child: const Text('Watch rewarded'),
      ),
    ]),
  );
}
```

### Bước 6️⃣ — Run thử

```bash
flutter run
```

**Đó là xong.** Default behavior bạn nhận được:

✅ **First-install VIP grace 24h** — user mới cài app KHÔNG thấy ad trong 24h đầu (boost retention D1)
✅ **Cupertino consent dialog** tự pop ~1s sau splash trên home screen (skip nếu VIP)
✅ **Splash app open ad** tự load + show + 30s hard cap
✅ **Banner** tự pause khi navigate sang screen khác, tự resume khi quay lại
✅ **Anti-fraud** 12 lớp tự bảo vệ tài khoản AdMob/AppLovin của bạn
✅ **VIP key redeem** — gọi `AdManager().vip!.redeemVip(...)` để cho user cash key VIP

---

## 🇬🇧 Quick start (English)

Same 6 steps as Vietnamese above. Replace VN strings:

```dart
consentDialogStrings: const ConsentDialogStrings(),  // English defaults
```

---

## ✨ Tính năng nổi bật (1.0.15)

| Feature | Mặc định | Tweak qua |
|---------|---------|-----------|
| **First-install VIP 24h grace** | ✅ ON (debug 30s) | `AdConfig.firstInstallVipGrace` |
| **Cupertino consent dialog auto-show** | ✅ ON, post-splash +1s | `AdConfig.autoShowConsentDialog` |
| **Smart App-Open timeout** | ✅ Lifecycle-aware (5s tick × 18, hard cap 90s) | — |
| **VIP auto-expire timer** | ✅ ON | — |
| **Banner pause/resume on route change** | ✅ ON | — |
| **Memory pressure log throttle** | ✅ 60s | — |
| **Diagnostic logs `roy93~`** | Verbose | `AdConfig.logLevel` |
| **Process-restart marker `🚀 CREATED`** | ✅ ON | — |
| **Adapter swap (admob ↔ applovin)** | 1 line | `AdConfig.provider` |

---

## 🎯 VIP system

### User redeem key (Cupertino dialog)

```dart
await AdManager().vip!.redeemVip(
  context,
  key: userInputKey,
  duration: const Duration(days: 30),
  validator: (key) => myServer.verifyVip(key),
  strings: AdConfig.instance.vipDialogStrings,
);
```

### Programmatic add (cho purchase / restore flow)

```dart
await AdManager().vip!.addVip(
  key: 'PURCHASE_${transactionId}',
  duration: const Duration(days: 365),
);
```

### Check VIP state

```dart
if (AdManager().vip!.isActive) { /* user là VIP */ }

ValueListenableBuilder<bool>(
  valueListenable: AdManager().vip!.activeListenable,
  builder: (_, active, __) => active ? VipBadge() : SizedBox.shrink(),
)
```

### Tắt first-install grace

```dart
AdConfig(
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  // ...
)
```

---

## 🛡️ Compliance (GDPR / COPPA / CCPA)

### Cách 1 — Cupertino dialog tự động (đơn giản nhất, recommended)

Mặc định SDK auto-show dialog ~1s sau splash. User chọn "Đồng ý" / "Từ chối", state lưu vào SharedPreferences. KHÔNG cần code thêm.

Re-show từ Settings page:
```dart
await ConsentManager.instance.showDialog(context);
```

### Cách 2 — Google UMP form (bắt buộc cho EEA users)

```dart
final r = await AdManager().requestUmpConsent(
  testMode: kDebugMode,
  debugGeography: DebugGeography.debugGeographyEea,
);
if (r.canRequestAds) {
  // tiếp tục init bình thường
}
```

### Cách 3 — Manual flag set (nếu có UI riêng)

```dart
await AdManager().setConsent(AdConsent(
  hasUserConsent: true,        // GDPR consent
  isAgeRestrictedUser: false,  // COPPA
  doNotSell: false,            // CCPA
));
```

### Checklist tuân thủ

- [ ] `app-ads.txt` đặt ở root domain
- [ ] Privacy Policy URL khai báo trong App Store / Play Store
- [ ] iOS ATT prompt — gọi `app_tracking_transparency` **trước** `AdManager().initialize`
- [ ] App cho trẻ em → set `isAgeRestrictedUser: true`

---

## 🐛 Debug

### DebugAdOverlay (floating panel)

```dart
runApp(MaterialApp(
  // ...
  builder: (context, child) => Stack(children: [
    child!,
    const DebugAdOverlay(),  // chỉ hiện trong kDebugMode
  ]),
));
```

Tap pill 🐛 Ad ở góc dưới → expand panel hiện realtime: slot states, VIP, init flag, safety status.

### Verbose logs

Tất cả SDK logs prefix `roy93~ [Tag]`. Ví dụ:
```
roy93~ [AdManager] 🚀 AdManager singleton CREATED — new Flutter process
roy93~ [AppLovinAdapter] inter [AppLovin] ✅ displayed | network=AppLovin creativeId=...
roy93~ [VipManager] ⏰ VIP entry expired — purging
roy93~ [AdManager] 🛡️ interstitial dismissed — app-open suppression armed
```

Pipe vào Crashlytics / Sentry:
```dart
AdConfig(
  onLog: (level, tag, msg) {
    if (level == AdLogLevel.error) FirebaseCrashlytics.instance.log('[$tag] $msg');
  },
  // ...
)
```

---

## ⚠️ Pitfalls (đọc trước khi báo bug)

### 1. KHÔNG set `android:taskAffinity=""`

Flutter create template default thêm dòng này vào `MainActivity`. **Xóa nó đi**. Lý do:
- AppLovin's full-screen ad activity inherit default affinity (= package name)
- MainActivity có `taskAffinity=""` → 2 activity ở 2 task khác nhau
- User HOME → reopen → tap X trên ad → no activity to return → user về launcher

### 2. iOS phải có `SKAdNetworkItems`

Thiếu cái này → AdMob/AppLovin không serve ads trên iOS 14.5+. Copy nguyên đoạn dài này từ [AdMob docs](https://developers.google.com/admob/ios/ios14#skadnetwork).

### 3. AppLovin KHÔNG có public test ad units

Khác AdMob, AppLovin yêu cầu register account + register test device. Mở `dash.applovin.com → MAX → Test Mode`.

SDK auto-register test device trong debug build dựa trên GAID — không cần manual nếu chỉ test debug.

### 4. `setNavigatorKey` trước `runApp`

Nếu không, consent dialog auto-show sẽ skip (no navigator context).

### 5. Init phải gọi trong `SplashScreen`, KHÔNG trong `main`

`SimpleEventBus().listen` phải register **trước** `AdManager().initialize()`. Nếu init trong main, listener không nhận được event init-complete.

---

## 📚 API Reference

### `AdConfig`

```dart
AdConfig({
  required AdProvider provider,                       // admob | appLovin
  AppLovinConfig? appLovin,                           // bắt buộc nếu provider == appLovin
  AdMobConfig? admob,                                 // bắt buộc nếu provider == admob

  // First-install VIP grace
  FirstInstallVipGrace firstInstallVipGrace =
      FirstInstallVipGrace.auto,                      // 30s debug / 24h release
  String firstInstallVipKey = '__FIRST_INSTALL__',

  // Consent
  bool autoShowConsentDialog = true,
  ConsentDialogStrings consentDialogStrings = const ConsentDialogStrings(),
  bool consentBarrierDismissible = false,
  Duration consentDialogPostSplashDelay = const Duration(seconds: 1),

  // Logging
  AdLogLevel logLevel = AdLogLevel.verbose,
  List<String>? logTagFilter,
  AdLogSink? onLog,

  // Safety / fraud
  AdSafetyParams safety = AdSafetyParams.auto,        // production | debug | custom

  // VIP
  Future<bool> Function(String key)? vipKeyValidator,
  VipDialogStrings vipDialogStrings = const VipDialogStrings(),

  // Splash
  Duration splashMaxDuration = const Duration(seconds: 8),
})
```

### `AdScreen`

Mixin-style base class cho screens hiển thị ads. Cung cấp:

```dart
Widget buildBanner();                                 // banner widget tự pause/resume
void showInterstitialAd({required onDone, ...});      // pre-check + buffer + show
void showRewardedAd({required onEarnedReward, ...});  // same
```

### `AdManager` singleton

```dart
AdManager().setNavigatorKey(key);                     // bắt buộc trước runApp
AdManager().initialize(config: ..., onComplete: ...); // gọi 1 lần ở splash
AdManager().destroy();                                // teardown để re-init
AdManager().setConsent(consent);                     // GDPR/COPPA/CCPA flags
AdManager().requestUmpConsent(...);                   // Google UMP wrapper
AdManager().showAppOpenAd(...);                       // splash flow
AdManager().showInterstitial(...);                    // hoặc dùng AdScreen.showInterstitialAd
AdManager().showRewardedAd(...);
AdManager().vip;                                      // VipManager (after init)
AdManager().consentManager;                           // ConsentManager
AdManager().events;                                   // Stream<AdEvent>
```

---

## 🚚 Migration

Từ `1.0.14` lên `1.0.15`: **không có breaking change**. Chỉ cần:

```yaml
applovin_admob_sdk: ^1.0.15
```

```bash
flutter pub get
```

Đọc `CHANGELOG.md` cho list đầy đủ bug fixes + features mới (consent dialog, UMP wrapper, first-install VIP grace, smart timeout, …).

Từ `1.x` lên `1.0.15`: xem `MIGRATION.md`.

---

## 🆘 Hỗ trợ

- **Bugs**: [GitHub Issues](https://github.com/royt93/FlutterBase2025/issues)
- **Demo app**: `packages/ad_sdk/example/lib/main.dart` — 13 demo pages
- **Architecture deep-dive**: `doc/architecture.md`

---

## 📄 License

MIT — see `LICENSE` file.
