# 📊 TÍCH HỢP QUẢNG CÁO (AdMob + AppLovin MAX) — FLUTTER

> Version: 20260324-v20 | SDK: `applovin_admob_sdk` v1.0.14 (pub.dev)
> Strict: Không `late`, không `!`, dùng nullable `?`, `ValueNotifier`, zero memory leak.

---

## 1. TỔNG QUAN

### 1.1 Provider Switch

```dart
// Chỉ đổi 1 dòng trong AdConfig:
provider: AdProvider.appLovin  // hoặc AdProvider.admob
```

### 1.2 Kiến trúc SDK Package

```
applovin_admob_sdk/
  ├── AdManager         # Singleton — quản lý toàn bộ ad lifecycle
  ├── AdScreen          # Base widget cho màn hình có ad
  ├── AdSafetyConfig    # Anti invalid traffic — 12 rules
  ├── AdLoadingDialog   # Dialog loading 1s trước fullscreen ad
  ├── BannerAdWidget    # Banner widget — dual provider, RouteAware
  ├── TopToast          # Animated toast khi ad chưa sẵn sàng
  ├── SimpleEventBus    # Splash ↔ AdManager bridge
  └── SafeLogger        # Production-safe logger
```

### 1.3 Ad Units

| Loại | AdMob Debug | AdMob Production | AppLovin MAX |
|------|-------------|-----------------|--------------|
| Banner | `ca-app-pub-3940256099942544/6300978111` | your_id | your_id |
| Interstitial | `ca-app-pub-3940256099942544/1033173712` | your_id | your_id |
| App Open | `ca-app-pub-3940256099942544/9257395921` | your_id | your_id |
| Rewarded | `ca-app-pub-3940256099942544/5224354917` | your_id | your_id |

---

## 2. GUARD MATRIX — TẤT CẢ CƠ CHẾ BẢO VỆ

| Guard | App Open | Inter | Rewarded | Banner |
|-------|:--------:|:-----:|:--------:|:------:|
| **Throttle 60s** giữa 2 fullscreen | ✅ | ✅ | ✅ | — |
| **Session cap** 6/session | ✅ | ✅ | ✅ | — |
| **Hourly cap** 3/giờ | ✅ | ✅ | ✅ | — |
| **Daily cap** 5/ngày (persistent) | ✅ | ✅ | ✅ | — |
| **Suspicious CTR** pause nếu CTR > 30% | ✅ | ✅ | ✅ | — |
| **Click spam** > 3 clicks/min | ✅ | ✅ | ✅ | ✅ |
| **Cold start skip** (chỉ show lần 2+) | ✅ | — | — | — |
| **Rapid resume** > 3 resume/min | ✅ | — | — | — |
| **Loading dialog 1s** trước fullscreen | ✅ | ✅ | ✅ | — |
| **Mutex `_isXxxLoading`** chống double load | ✅ | ✅ | ✅ | — |
| **`_isInterstitialShowing`** chống App Open | ✅ | — | — | — |
| **`_lastFullscreenDismissTime`** cooldown 2s | ✅ | — | — | — |
| **Navigation cooldown 5s** | — | — | — | ✅ |

---

## 3. INTEGRATION GUIDE — STEP BY STEP (Fresher Dev)

> ⏱ Thời gian ước tính: **~60 phút**
> 📋 Đọc hết phần này trước khi bắt đầu. Làm từng bước, không skip.

---

### STEP 1: Thêm Dependencies — `pubspec.yaml`

```yaml
dependencies:
  applovin_admob_sdk: ^1.0.14
  gma_mediation_applovin: ^1.0.0  # chỉ nếu dùng AppLovin
```

```bash
flutter pub get
```

✅ **Kiểm tra:** Terminal không có lỗi đỏ.

---

### STEP 2: Android Config — `android/app/build.gradle.kts`

```kotlin
android {
    defaultConfig {
        minSdk = 21   // phải >= 21
    }
    buildFeatures {
        buildConfig = true
    }
}

dependencies {
    implementation("com.google.ads.mediation:applovin:13.2.0.1")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
}
```

✅ **Kiểm tra:** `flutter build apk --debug` thành công.

---

### STEP 3: AndroidManifest.xml

Mở `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest>
    <!-- Permission (trước <application>) -->
    <uses-permission android:name="com.google.android.gms.permission.AD_ID" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application ...>
        <!-- AdMob App ID (bắt buộc dù dùng AppLovin) -->
        <meta-data
            android:name="com.google.android.gms.ads.APPLICATION_ID"
            android:value="ca-app-pub-XXXXXXXXXXXXXXXX~XXXXXXXXXX" />

        <!-- KHÔNG thêm applovin.sdk.key ở đây — SDK Key truyền qua Dart -->
    </application>
</manifest>
```

---

### STEP 4: Đăng ký Navigator Key + Route Observers — `main.dart`

> 🔑 **ĐÂY LÀ BƯỚC QUAN TRỌNG NHẤT.** Nếu bỏ qua:
> - Banner sẽ crash khi navigate (thiếu `adRouteObserver`)
> - App Open on resume sẽ KHÔNG có loading dialog (thiếu `navigatorKey`)

```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

// 👇 Tạo navigator key GLOBAL
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 👇 Đăng ký navigator key cho SDK — TRƯỚC runApp()
  AdManager().setNavigatorKey(navigatorKey);

  runApp(
    MaterialApp(
      // 👇 3 dòng BẮT BUỘC
      navigatorKey: navigatorKey,
      navigatorObservers: [
        adRouteObserver,        // RouteAware Banner pause/resume
        AdScreenRouteLogger(),  // Log route changes (debug)
      ],
      home: const SplashScreen(),
    ),
  );
}
```

**Nếu dùng GetX:**
```dart
GetMaterialApp(
  navigatorKey: navigatorKey,
  navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
  home: const MyApp(),
)
```

✅ **Kiểm tra:** Chạy app, log có:
```
setNavigatorKey: registered ✅
[AdScreen~Router] ➡️ PUSH: / (from: null)
```

---

### STEP 5: Splash Screen — Nơi Khởi Động Ad

> ⚠️ `AdManager().initialize()` **BẮT BUỘC gọi trong SplashScreen**, không phải trong `main()`.
> Lý do: EventBus phải fire SAU khi listener đã đăng ký.

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

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
    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // Skip ad nếu đã vào app rồi (hot restart)
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigateHome());
      return;
    }

    // Hard cap 8s — tránh stuck splash
    _hardCapTimer = Timer(const Duration(seconds: 8), () => _navigateHome());

    // Đăng ký EventBus TRƯỚC khi gọi initialize()
    _eventListener = (event) {
      if (event.value) {
        _loadAndShowAppOpenAd();
      } else {
        _navigateHome(); // init fail
      }
    };
    SimpleEventBus().listen(_eventListener!);

    // Initialize AdManager trong postFrameCallback
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().initialize(
        config: const AdConfig(
          provider: AdProvider.appLovin,  // đổi thành .admob nếu dùng AdMob
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
          vipDeviceGaids: [],
          loadingBufferMs: 1000,
          adNotReadyMessage: 'Ad chưa sẵn sàng, vui lòng thử lại.',
          adLoadingMessage: 'Đang tải…',
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
        // SDK sẽ tự show loading dialog 1s trước ad
        AdLoadingDialog.showAdBuffer(context, onComplete: () {
          if (!mounted) { _navigateHome(); return; }
          _hardCapTimer?.cancel(); // cancel timer trước khi show ad
          AdManager().showAppOpenAd(
            bypassSafety: true,
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
    if (_eventListener != null) {
      SimpleEventBus().remove(_eventListener!);
      _eventListener = null;
    }
    AdManager().markSplashInactive(); // gọi ĐÚNG 1 lần
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
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
```

✅ **Kiểm tra log:**
```
[AdManager] ###init called, provider=AdProvider.appLovin
[AdManager] ###init completed
[AdManager] loadAppOpenAd [AppLovin] 🔄 requesting...
[AdManager] ✅ [AppLovin] App Open Ad Loaded
[AdLoadingDialog] showAdBuffer: showing dialog, bufferMs=1000
[AdManager] markSplashInactive
```

---

### STEP 6: Màn Hình Có Ads — Kế thừa `AdScreen`

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

// Kế thừa AdScreen thay vì StatefulWidget
class HomeScreen extends AdScreen {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

// Kế thừa AdScreenState<T> thay vì State<T>
class _HomeScreenState extends AdScreenState<HomeScreen> {

  void _goToNextScreen() {
    // Loading dialog 1s tự hiện → ad show → onDone gọi
    showInterstitialAd(onDone: (shown) {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DetailScreen()));
    });
  }

  void _watchAdForCoins() {
    showRewardedAd(onEarnedReward: (earned) {
      if (!mounted) return;
      if (earned) {
        // User xem hết ad → trao thưởng
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('+10 coins!')),
        );
      }
      // earned=false → ad bị skip hoặc không sẵn sàng (SDK tự show TopToast)
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          buildBanner(),  // 👈 Banner tự quản lý lifecycle
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    onPressed: _goToNextScreen,
                    child: const Text('Go to Detail (Inter Ad)'),
                  ),
                  ElevatedButton(
                    onPressed: _watchAdForCoins,
                    child: const Text('Watch Ad for 10 Coins'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

> 📌 `AdScreenState` tự động gọi `loadInterstitial()` trong `initState`. Nếu SDK chưa init → SDK sẽ bỏ qua (không crash).

---

### STEP 7: App Open On Resume — TỰ ĐỘNG

SDK tự handle qua `WidgetsBindingObserver`. Bạn KHÔNG cần viết thêm gì.

**Flow khi user quay lại app:**
```
App background ≥ 5s
  → User mở lại app
  → SDK check: canShowAppOpenOnResume()
  → Nếu OK: show AdLoadingDialog 1s → show App Open Ad
  → Nếu blocked: log lý do, skip (bình thường)
```

> ⚠️ **Bắt buộc:** Phải gọi `AdManager().setNavigatorKey(navigatorKey)` ở `main()` để SDK có thể show loading dialog khi resume.

---

## 4. LUỒNG APP OPEN AD — 6 KỊCH BẢN

### Kịch bản 1: Init thành công + Load nhanh (lý tưởng)
```
markSplashActive()
  → initialize() → EventBus(true)
  → loadAppOpenAd() → loaded < 8s
  → AdLoadingDialog 1s → showAppOpenAd(bypassSafety: true)
  → User đóng → markSplashInactive() → MainScreen
```

### Kịch bản 2: Load chậm > 8s
```
Timer 8s hết → navigateHome() → MainScreen
Ad load về → _hasNavigated=true → BLOCKED
Ad nằm trong RAM → Resume sau sẽ show
```

### Kịch bản 3: Load thất bại
```
onAdLoaded(false) → navigateHome() → MainScreen (sớm hơn 8s)
```

### Kịch bản 4: Init thất bại
```
EventBus(false) → navigateHome() → MainScreen
```

### Kịch bản 5: App Resume — Show thành công
```
App background → User quay lại
  → showAppOpenAdOnResume()
  → canShowAppOpenOnResume() = true
  → AdLoadingDialog 1s (spinner)
  → showAppOpenAd(bypassSafety: true)
  → User đóng → preload next
```

### Kịch bản 6: App Resume — Bị chặn
```
Background < 5s hoặc throttle active
  → canShowAppOpenOnResume() = false → skip
  → KHÔNG show ad, KHÔNG show dialog
```

---

## 5. AD SAFETY — 12 BIỆN PHÁP CHỐNG INVALID TRAFFIC

### 5.1 `canShowFullscreenAd()` — 7 Checks

| # | Check | Giới hạn | Fail log |
|---|-------|----------|----------|
| 1 | Suspicious pause | 30m→1h→2h→4h→8h | `🛡️ Suspended` |
| 2 | Session age | > 10s | `🛡️ Session too young` |
| 3 | Session cap | ≤ 6/session | `🛡️ Session limit` |
| 4 | Hourly cap | ≤ 3/giờ | `🛡️ Hourly cap` |
| 5 | Daily cap | ≤ 5/ngày | `🛡️ Daily limit` |
| 6 | Throttle | ≥ 60s | `🛡️ Throttle: wait Xs` |
| 7 | CTR anomaly | ≤ 30% (≥ 5 imp) | `⚠️ SUSPICIOUS` |

### 5.2 `canShowAppOpenOnResume()` — 4 Checks

| # | Check | Fail log |
|---|-------|----------|
| 1 | Cold start skip | `🛡️ Skipping on cold start` |
| 2 | Background < 5s | `🛡️ Resume too fast` |
| 3 | Rapid resume > 3/min | `🛡️ Rapid resume detected` |
| 4 | Fullscreen throttle | `🛡️ Throttle: wait Xs` |

### 5.3 Progressive Suspension

```
Vi phạm 1 → Pause 30 phút
Vi phạm 2 → Pause 1 giờ
Vi phạm 3 → Pause 2 giờ
Vi phạm 5+ → Pause 8 giờ (max 24 giờ)
```

---

## 6. LOG REFERENCE

> Tất cả log có prefix `[AdMob]` hoặc `[AppLovin]` để phân biệt.

### 6.1 Log tốt
```
✅ Ad Loaded / Shown / Dismissed      ← Hoạt động bình thường
📊 Ad SHOWN | session=X/6 | hourly=X/3 | daily=X/5
[AdLoadingDialog] showAdBuffer: showing dialog, bufferMs=1000
```

### 6.2 Log warning (bình thường)
```
⏭️ already loading, skip             ← Mutex lock (tốt)
⏭️ ad already ready                  ← AppLovin guard
🛡️ Throttle: wait Xs                 ← Safety hoạt động đúng
⚠️ AdManager not initialized         ← SDK chưa init, method bị skip
```

### 6.3 Log cần chú ý
```
⚠️ SUSPICIOUS                        ← CTR/click spam → kiểm tra
❌ Failed to load                     ← Network/config issue
```

---

## 7. FILL RATE OPTIMIZATION

| Cơ chế | Mô tả |
|--------|-------|
| **Sequential preload** | App Open loaded → auto load Inter + Rewarded |
| **Auto-reload on dismiss** | Mọi ad type reload ngay khi user đóng |
| **Auto-reload on fail** | Reload khi show thất bại |
| **5-min retry timer** | Check + fill ad slots trống mỗi 5 phút |
| **4h expiry reload** | AdMob App Open hết hạn → auto reload |
| **Error cooldown 15min** | Tránh spam server khi load thất bại liên tục |

---

## 8. MEMORY LEAK PREVENTION

| Cơ chế | Mô tả |
|--------|-------|
| **Callback null before dispose** | Tránh late callback |
| **EventBus clearAll()** | Xoá listeners trong destroy() |
| **Observer paired** | add/remove observer đúng cặp |
| **ValueNotifier reset** | Reset value, KHÔNG dispose (singleton lifetime) |
| **Pending callback flush** | Tất cả pending callbacks fire(false) trước null |
| **Static state reset** | AdLoadingDialog, AdSafetyConfig reset trong destroy() |

---

## 9. CHECKLIST TRƯỚC KHI RELEASE

- [ ] Đổi ad unit ID từ test → production trong `AdConfig`
- [ ] Kiểm tra `vipDeviceGaids` đúng danh sách
- [ ] Kiểm tra `AdProvider` đúng (admob vs appLovin)
- [ ] Kiểm tra `AndroidManifest.xml` có AdMob Application ID
- [ ] Test trên real device (emulator không show ad thật)
- [ ] Xem log không có `⚠️ SUSPICIOUS` bất thường
- [ ] Kiểm tra `daily=X/5` tăng đúng sau mỗi phiên test

---

## 10. TROUBLESHOOTING

### "AdManager not initialized" warning
**Khi nào xảy ra:** `AdScreenState.initState` gọi `loadInterstitial()` trước khi `initialize()` hoàn thành.
**Fix:** SDK v1.0.14+ tự bỏ qua (warning log, không crash). Đảm bảo `initialize()` được gọi trong SplashScreen.

### "AdWidget is already in the Widget tree" (AdMob)
**Fix:** SDK dùng `_admobIsTopRoute` per-widget flag, chỉ 1 AdWidget trong tree mỗi lúc.

### Banner bị stuck shimmer (AppLovin)
**Fix:** SDK dùng `Stack` — MaxAdView luôn mounted, shimmer overlay lên trên.

### App Open show cùng lúc Interstitial
**Fix:** `_isInterstitialShowing` guard + `_lastFullscreenDismissTime` 2s cooldown.

### "Ad not ready" toast hiện liên tục
**Lý do:** Safety throttle active (60s giữa 2 ad). Chờ và thử lại.

### App Open resume không có loading dialog
**Fix:** Phải gọi `AdManager().setNavigatorKey(navigatorKey)` trong `main()`.

---

## 11. SDK INTERNALS — FLOW CHI TIẾT

### 11.1 Interstitial Flow
```
AdScreen.showInterstitialAd()
  → canShowInterstitial() pre-check (safety + dialog guard)
  → AdLoadingDialog 1s buffer
  → AdManager.showInterstitial()
    → canShowFullscreenAd() recheck
    → [AdMob] ad.show() / [AppLovin] MAX.show()
    → dismiss → dispose + reload
```

### 11.2 Rewarded Flow
```
AdScreen.showRewardedAd()
  → VIP? → auto-reward true
  → canShowRewardedAd() pre-check
    → fail? → TopToast + false
  → AdLoadingDialog 1s buffer
  → AdManager.showRewardedAd()
    → earned → callback(true)
    → skip → callback(false) + reload
```

### 11.3 Banner Flow
```
BannerAdWidget mount
  → RouteAware subscribe
  → _initBanner() (1 lần)
    → VIP/no internet/cooldown → skip
    → [AdMob] loadBanner / [AppLovin] preloaded
  → Route navigation:
    didPushNext → pause
    didPopNext → resume
  → App lifecycle:
    paused → hide
    resumed → show + auto-reload on error
```

---

## 12. PHIÊN BẢN

| Ngày | Version | Thay đổi |
|------|---------|----------|
| 20260321 | v1–v12 | Port từ Kotlin → Flutter, 12 iterations |
| 20260322 | v13–v17 | Provider labels, setState fix, AdWidget fix |
| 20260323 | v18 | SDK Package `applovin_admob_sdk`, 43 bug fixes |
| 20260324 | v19 | Fix #47: Loading dialog cho App Open resume via navigator key |
| **20260324** | **v20** | **Fix #48: _assertInitialized không crash + doc update** |
`, "Complexity": 8, "Description": "Complete rewrite of AD.MD for the updated SDK package approach (pub.dev) with navigator key, loading dialog, and fresher-friendly guide.", "EmptyFile": false, "IsArtifact": false, "Overwrite": true, "TargetFile": "/Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_260321_FlutterBase2025/doc/AD.MD"}
