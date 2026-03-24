# 📊 TÍCH HỢP QUẢNG CÁO (AdMob + AppLovin MAX) — FLUTTER

> Version: 20260324-v19 | Provider: AdMob & AppLovin MAX (dual) | SDK: applovin_admob_sdk v1.0.13
> Strict: Không `late`, không `!`, dùng nullable `?`, `ValueNotifier`, zero memory leak.

---

## 1. TỔNG QUAN KIẾN TRÚC

### 1.1 Provider Switch

```
kIsEnableAdmob = true  → google_mobile_ads (AdMob)
kIsEnableAdmob = false → applovin_max (AppLovin MAX)
```

Chỉ cần đổi **1 dòng** trong `k/k.dart` → toàn bộ ad tự chuyển provider.

### 1.2 Cấu trúc file

```
lib/mckimquyen/ad/
  ├── k/k.dart                     # Constants, Ad IDs, provider flag
  ├── ad_manager.dart              # Singleton core — dual provider
  ├── ad_safety_config.dart        # Anti invalid traffic — 12 rules
  ├── ad_screen.dart               # Base class cho Screen có Inter/Banner
  ├── screen_a.dart                # Demo: Inter + Banner + Rewarded
  ├── utils/
  │   ├── safe_logger.dart         # Production-safe logger
  │   ├── app_preferences.dart     # SharedPreferences wrapper
  │   └── event_bus.dart           # Splash ↔ AdManager bridge
  └── widget/
      ├── banner_ad_widget.dart    # Banner widget — dual provider
      └── shimmer_view.dart        # Shimmer placeholder animation
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

| Guard | App Open | Interstitial | Rewarded | Banner |
|-------|:--------:|:------------:|:--------:|:------:|
| **Throttle 60s** giữa 2 fullscreen | ✅ | ✅ | ✅ | — |
| **Session cap** 6/session | ✅ | ✅ | ✅ | — |
| **Hourly cap** 3/giờ | ✅ | ✅ | ✅ | — |
| **Daily cap** 5/ngày (persistent) | ✅ | ✅ | ✅ | — |
| **Suspicious CTR** pause nếu CTR > 30% | ✅ | ✅ | ✅ | — |
| **Click spam** > 3 clicks/min | ✅ | ✅ | ✅ | ✅ |
| **Cold start skip** (chỉ show lần 2+) | ✅ | — | — | — |
| **Rapid resume** > 3 resume/min | ✅ | — | — | — |
| **Mutex `_isXxxLoading`** chống double load | ✅ | ✅ | ✅ | — |
| **In-memory guard** skip reload nếu ad còn trong RAM | ✅ 4h | ✅ | ✅ | — |
| **`_isInterstitialShowing`** chống App Open trong khi Inter hiện | ✅ | — | — | — |
| **`_isRewardedShowing`** chống App Open trong khi Rewarded hiện | ✅ | — | — | — |
| **`_isMaxInterReady`** guard (AppLovin) | — | ✅ | — | — |
| **Navigation cooldown 5s** | — | — | — | ✅ |
| **`_admobIsTopRoute`** per-widget (chống double AdWidget) | — | — | — | ✅ AdMob |
| **`wasActuallyShown` log** phân biệt blocked vs dismissed thật | ✅ | — | — | — |

---

## 3. INTEGRATION GUIDE — STEP BY STEP (Fresher Dev)

> ⏱ Thời gian ước tính: **~90 phút**
> 📋 Đọc hết phần này trước khi bắt đầu. Làm từng bước, không skip.

---

### STEP 1: Thêm Dependencies — `pubspec.yaml`

Mở file `pubspec.yaml` ở root project, thêm vào section `dependencies`:

```yaml
dependencies:
  # Ad SDKs
  google_mobile_ads: ^6.0.0
  applovin_max: ^4.6.3

  # Utilities (bắt buộc)
  shared_preferences: ^2.5.3
  connection_notifier: ^2.0.1
```

Sau đó chạy terminal:
```bash
flutter pub get
```

✅ **Kiểm tra:** Terminal không có lỗi đỏ.

---

### STEP 2: Android Config — `android/app/build.gradle.kts`

> ⚠️ Project mới dùng `.kts` (Kotlin DSL). Nếu project dùng `.gradle` (Groovy) thì cú pháp khác nhau.

Mở file `android/app/build.gradle.kts`, tìm block `android { }` và thêm:

```kotlin
android {
    // ... các config khác ...
    buildFeatures {
        buildConfig = true   // Cần cho BuildConfig.DEBUG
    }
}

dependencies {
    // ... các dep khác ...
    implementation("com.google.ads.mediation:applovin:13.2.0.1")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
}
```

✅ **Kiểm tra:** Build thành công (chạy `flutter build apk --debug`).

---

### STEP 3: AndroidManifest.xml

Mở `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- THÊM 3 permissions này nếu chưa có -->
    <uses-permission android:name="com.google.android.gms.permission.AD_ID" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application
        android:label="YourApp"
        ... >

        <!-- THÊM meta-data AdMob App ID (bắt buộc dù dùng AppLovin) -->
        <meta-data
            android:name="com.google.android.gms.ads.APPLICATION_ID"
            android:value="ca-app-pub-XXXXXXXXXXXXXXXX~XXXXXXXXXX" />

        <!-- KHÔNG thêm applovin.sdk.key ở đây — SDK v13+ crash nếu thêm -->
        <!-- SDK Key truyền qua AppLovinMAX.initialize() trong Dart -->

        <activity ... />
    </application>
</manifest>
```

> 📌 Lấy AdMob Application ID từ [AdMob Console](https://apps.admob.com) → Apps → App settings.

✅ **Kiểm tra:** App vẫn build và run được sau khi thêm manifest.

---

### STEP 4: Copy Thư Mục Ad vào Project Mới

Copy **toàn bộ** thư mục từ project nguồn vào project đích:

```
lib/mckimquyen/ad/           →  lib/[your_package]/ad/
lib/mckimquyen/core/         →  lib/[your_package]/core/    ← chứa BaseStatefulState
```

> ⚠️ `BaseStatefulState` là dependency của `AdScreenState`. Không copy sẽ bị lỗi compile.

Sau khi copy, cập nhật tất cả `import` trong các file ad:
```dart
// Đổi từ:
import 'package:saigonphantomlabs/mckimquyen/...';
// Thành:
import 'package:[your_package_name]/[your_path]/...';
```

Chạy `flutter analyze` để xem còn lỗi import nào không.

✅ **Kiểm tra:** `flutter analyze` không còn lỗi trong thư mục `ad/`.

---

### STEP 5: Cấu hình Ad IDs — `k/k.dart`

Mở `lib/[your_package]/ad/k/k.dart`, điền đúng ID của bạn:

```dart
import 'package:flutter/foundation.dart';

// ═══════ BƯỚC 1: Chọn provider ═══════
// true  = dùng Google AdMob
// false = dùng AppLovin MAX
const bool kIsEnableAdmob = false;

// ═══════ BƯỚC 2: AppLovin Config ═══════
// Lấy từ AppLovin Dashboard → Ad Units
const String kAppLovinSdkKey         = "YOUR_APPLOVIN_SDK_KEY";
const String kAppLovinBannerId        = "YOUR_BANNER_UNIT_ID";
const String kAppLovinInterstitialId  = "YOUR_INTER_UNIT_ID";
const String kAppLovinAppOpenId       = "YOUR_APP_OPEN_UNIT_ID";
const String kAppLovinRewardedId      = "YOUR_REWARDED_UNIT_ID";

// ═══════ BƯỚC 3: AdMob Config ═══════
// kDebugMode = true tự động khi chạy debug (flutter run)
// kDebugMode = false tự động khi build release
const String kAdmobBannerAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/6300978111"      // ID test chính thức của Google
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";      // ID production của bạn

const String kAdmobInterstitialAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/1033173712"
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";

const String kAdmobAppOpenAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/9257395921"
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";

const String kAdmobRewardedAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/5224354917"
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";

// ═══════ BƯỚC 4: Test Devices (AdMob) ═══════
// Xem GAID hash trong logcat sau khi chạy app lần đầu —
// log sẽ có dạng: "Use RequestConfiguration.Builder().setTestDeviceIds(Arrays.asList("HASH"))"
const List<String> kTestDeviceIds = [
  "YOUR_TEST_DEVICE_HASH",   // Hash MD5 của GAID thiết bị test
];

// ═══════ BƯỚC 5: VIP Devices (tùy chọn) ═══════
// GAID của các thiết bị này sẽ KHÔNG bao giờ thấy quảng cáo
const List<String> kVipDeviceGaids = [
  // "your-gaid-uuid",
];
```

✅ **Kiểm tra:** Không có lỗi compile sau khi lưu file.

---

### STEP 6: Đăng ký AdRouteObserver trong `main.dart`

> 🔑 **Đây là bước quan trọng nhất cho Banner Ad.** Nếu bỏ qua, `BannerAdWidget` sẽ không nhận được sự kiện navigation (pause/resume) và banner sẽ crash khi navigate giữa các màn hình.

**Cách thêm với `GetMaterialApp` (GetX):**

```dart
import 'package:[your_package]/ad/ad_route_observer.dart'; // THÊM import này

final navigatorKey = GlobalKey<NavigatorState>(); // THÊM navigator key

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ✅ Đăng ký navigator key — SDK cần key này để show loading dialog
  // khi App Open Ad hiển thị từ background → foreground
  AdManager().setNavigatorKey(navigatorKey);
  // ... các init khác ...
  runApp(
    GetMaterialApp(
      // ... các config khác ...

      navigatorKey: navigatorKey,  // THÊM navigator key

      // THÊM 2 observers này — BẮT BUỘC
      navigatorObservers: [
        adRouteObserver,        // RouteAware cho BannerAdWidget pause/resume
        AdScreenRouteLogger(),  // Log navigation để debug
      ],

      home: const MyApp(),
    ),
  );
}
```

**Cách thêm với `MaterialApp` thông thường:**

```dart
import 'package:[your_package]/ad/ad_route_observer.dart';

MaterialApp(
  navigatorObservers: [
    adRouteObserver,
    AdScreenRouteLogger(),
  ],
  home: SplashScreen(),
)
```

> ✅ `AdManager` tự gắn `WidgetsBindingObserver` trong constructor — **KHÔNG cần** gắn thêm ở `main.dart`.

✅ **Kiểm tra:** Chạy app và navigate giữa 2 màn hình, log phải có:
```
[roy93~Router] ➡️ PUSH: /ScreenA (from: /MainScreen)
[roy93~Banner] RouteAware.didPush() ▶️ [AdMob] scheduling _admobIsTopRoute=true
```

---

### STEP 7: Splash Screen — Nơi Khởi Động Ad

Splash Screen là nơi DUY NHẤT gọi `AdManager().initialize()`. Copy pattern sau:

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:[your_package]/ad/ad_manager.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  bool _hasNavigated = false;
  StreamSubscription<bool>? _subscription;

  @override
  void initState() {
    super.initState();
    _startSplash();
  }

  void _startSplash() {
    // 1) Đánh dấu Splash đang active — chặn AppOpen Resume trigger
    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // 2) Hard-cap timer 8s: nếu SDK chậm, user vẫn vào được app
    Future.delayed(const Duration(seconds: 8), () {
      _navigateToMainSafely(initAdSuccess: false);
    });

    // 3) Lắng nghe AdManager báo init xong qua EventBus
    _subscription = AdManager().eventBusStream.listen((success) {
      if (success) {
        _loadAndShowAppOpenAd(); // Init OK → thử show App Open Ad
      } else {
        _navigateToMainSafely(initAdSuccess: false); // Init fail → vào app luôn
      }
    });

    // 4) Bắt đầu init AdManager (gọi 1 lần duy nhất)
    AdManager().initialize(
      onComplete: (success, _) {
        // EventBus đã xử lý, không cần làm gì ở đây
      },
    );
  }

  void _loadAndShowAppOpenAd() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (!mounted || _hasNavigated) return;
      if (loaded) {
        AdManager().showAppOpenAd(
          bypassSafety: true, // Bỏ qua AdSafety cho lần đầu (splash)
          onAdDismiss: (_) => _navigateToMainSafely(initAdSuccess: true),
        );
      } else {
        _navigateToMainSafely(initAdSuccess: false);
      }
    });
  }

  void _navigateToMainSafely({required bool initAdSuccess}) {
    if (_hasNavigated) return; // Guard chống navigate 2 lần
    _hasNavigated = true;
    _subscription?.cancel();
    AdManager().markSplashInactive(); // Từ đây AppOpen Resume có thể kích hoạt
    // TODO: Thay bằng navigation method của bạn
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const MainScreen()),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
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

✅ **Kiểm tra log sau khi chạy:**
```
[roy93~AdManager] markSplashActive
[roy93~AdManager] ###init called, isEnableAdmob=false
[roy93~AdManager] ###init completed, calling onComplete
[roy93~AdManager] loadAppOpenAd [AppLovin] 🔄 requesting ad...
[roy93~AdManager] ✅ [AppLovin] App Open Ad Loaded
[roy93~AdManager] markSplashInactive
```

---

### STEP 8: Màn Hình Có Ads — Kế thừa `AdScreen`

Mọi màn hình muốn có Interstitial/Rewarded Ad phải kế thừa `AdScreen` thay vì `StatefulWidget`:

```dart
import 'package:flutter/material.dart';
import 'package:[your_package]/ad/ad_screen.dart';
import 'package:[your_package]/ad/ad_manager.dart';

// STEP 8a: Kế thừa AdScreen thay vì StatefulWidget
class HomeScreen extends AdScreen {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

// STEP 8b: Kế thừa AdScreenState<T> thay vì State<T>
class _HomeScreenState extends AdScreenState<HomeScreen> {

  @override
  void initState() {
    super.initState(); // AdScreenState.initState() tự gọi loadInterstitial()
    // Thêm init riêng của màn hình ở đây nếu cần
  }

  // STEP 8c: Show interstitial trước khi navigate
  void _goToNextScreen() {
    showInterstitialAd(onDone: (shown) {
      if (!mounted) return;
      // Dù ad show hay không (shown=true/false), vẫn navigate
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DetailScreen()));
    });
  }

  // STEP 8d: Show rewarded ad để nhận phần thưởng
  void _watchAdForReward() {
    showRewardedAd(onEarnedReward: (earned) {
      if (!mounted) return;
      if (earned) {
        // User đã xem đủ → trao thưởng
        setState(() { /* cộng coins, mở tính năng, ... */ });
      }
      // earned=false: ad bị skip hoặc safety blocked → không trao thưởng
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    onPressed: _goToNextScreen,
                    child: const Text('Go to Detail'),
                  ),
                  ElevatedButton(
                    onPressed: _watchAdForReward,
                    child: const Text('Watch Ad for Reward'),
                  ),
                ],
              ),
            ),
          ),
          // STEP 8e: Banner Ad — đặt ở cuối màn hình
          buildBanner(), // Gọi method từ AdScreenState, không new BannerAdWidget()
        ],
      ),
    );
  }
}
```

> 📌 Dùng `buildBanner()` (method của `AdScreenState`) thay vì `const BannerAdWidget()` trực tiếp — để có log tracking.

✅ **Kiểm tra log khi mở màn hình:**
```
[roy93~AdScreen] initState _HomeScreenState — preloading interstitial
[roy93~AdScreen] buildBanner _HomeScreenState
[roy93~Banner] initState — isEnableAdmob=false
[roy93~Banner] RouteAware subscribed to /HomeScreen
[roy93~Banner] _initBanner ✅ allowed, proceeding...
```

---

### STEP 9: Màn Hình CHỈ Có Banner (Không Có Inter/Rewarded)

Nếu màn hình chỉ cần banner, không cần Inter/Rewarded, vẫn dùng `AdScreen` nhưng không gọi `showInterstitialAd`:

```dart
class SimpleScreen extends AdScreen {
  const SimpleScreen({super.key});
  @override
  State<SimpleScreen> createState() => _SimpleScreenState();
}

class _SimpleScreenState extends AdScreenState<SimpleScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const Expanded(child: Center(child: Text('Content'))),
          buildBanner(), // Chỉ cần dòng này
        ],
      ),
    );
  }
}
```

---

### STEP 10: Màn Hình KHÔNG Có Banner

Nếu màn hình không cần bất kỳ ad nào, dùng `StatefulWidget` bình thường — **không kế thừa AdScreen**.

```dart
class NoAdScreen extends StatefulWidget {
  const NoAdScreen({super.key});
  @override
  State<NoAdScreen> createState() => _NoAdScreenState();
}

class _NoAdScreenState extends State<NoAdScreen> {
  // Không import gì liên quan đến ad
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const Center(child: Text('No ads here')));
  }
}
```

---

### STEP 11: Tuỳ chỉnh AdSafety Limits

Mở `lib/[your_package]/ad/ad_safety_config.dart`:

```dart
// Thời gian tối thiểu giữa 2 fullscreen ad (ms)
static const int _minTimeBetweenFullscreenAds = 60000;  // 60s (khuyên giữ nguyên)

// Giới hạn số lần show
static const int _maxFullscreenAdsPerSession = 6;   // 6 lần/session
static const int _maxFullscreenAdsPerHour    = 3;   // 3 lần/giờ
static const int _maxFullscreenAdsPerDay     = 5;   // 5 lần/ngày

// App Open: bỏ qua resume nếu background quá ngắn
static const int _minTimeAppOpenResume       = 5000; // ≥ 5s

// Anti-fraud
static const double _suspiciousCtrThreshold  = 0.30; // CTR > 30% → suspend
static const int    _maxClicksPerMinute      = 3;    // > 3 click/min → suspend
```

---

### STEP 12: Verification Checklist

Sau khi tích hợp xong, test lần lượt các kịch bản sau:

| # | Kịch bản | Log cần thấy | Pass? |
|---|----------|--------------|-------|
| 1 | Mở app lần đầu | `###init completed` | ☐ |
| 2 | App Open Splash show | `✅ App Open Ad Shown` | ☐ |
| 3 | Navigate A → B | `didPushNext ⏸️` trên A, `didPush ▶️` trên B | ☐ |
| 4 | Navigate back B → A | `didPop ⏹️` B, `didPopNext ▶️` A (postFrame) | ☐ |
| 5 | Banner load | `✅ Banner Ad Loaded` | ☐ |
| 6 | Interstitial show | `✅ Interstitial Ad Shown` | ☐ |
| 7 | Rewarded show | `✅ Rewarded Ad Shown` | ☐ |
| 8 | App → Background → Foreground | `⏸️ App went to BACKGROUND` → `▶️ App came to FOREGROUND` | ☐ |
| 9 | App Open Resume | `showAppOpenAdOnResume triggered` | ☐ |
| 10 | Navigation spam | `canLoadBanner ⏭️ cooldown active` | ☐ |

> 🔴 Nếu thấy log `❌`, `SUSPICIOUS`, hoặc exception trong console → báo ngay Senior Dev.

---


## 4. LUỒNG APP OPEN AD — 6 KỊCH BẢN

### Kịch bản 1: SDK init SUCCESS + Load thành công < 8s (Lý tưởng)
```
markSplashActive()
  → initialize() → EventBus(true)
  → loadAppOpenAd() → onAdLoaded(true) < 8s
  → showAppOpenAd(bypassSafety: true)
  → User đóng Ad → markSplashInactive() → MainScreen
```

### Kịch bản 2: SDK init SUCCESS + Load thành công > 8s (Chậm mạng)
```
markSplashActive()
  → Timer 8s hết → _navigateToMainSafely() → MainScreen
  → Ad load về nhưng _hasNavigated = true → BLOCKED, không show
  → Ad nằm trong RAM → Resume tiếp theo sẽ show
```

### Kịch bản 3: SDK init SUCCESS + Load THẤT BẠI < 8s
```
markSplashActive()
  → onAdLoaded(false) → _navigateToMainSafely() → MainScreen (sớm hơn 8s)
```

### Kịch bản 4: SDK init THẤT BẠI
```
markSplashActive()
  → EventBus(false) → _navigateToMainSafely() → MainScreen
```

### Kịch bản 5: App Resume — Show thành công
```
App về Background → Ad đã sẵn sàng trong RAM
  → User vào lại App → showAppOpenAdOnResume()
  → AdSafety.canShowAppOpenOnResume() = true
  → adReady=true, isShowing=false
  → AdLoadingDialog hiển thị 1s (spinner) — cần setNavigatorKey()
  → showAppOpenAd(bypassSafety: true)
  → User đóng → preload next
```

### Kịch bản 6: App Resume — Bị chặn bởi Safety
```
App về Background (< 60s trước)
  → User vào lại App → showAppOpenAdOnResume()
  → AdSafety.canShowFullscreenAd() = false (throttle/cap)
  → showAppOpenAd blocked → onAdDismiss(false)
  → "ProcessLifecycle 🔄 Ad blocked/skipped, preloading for next resume"
  → Không log "dismissed" giả ← (Fixed!)
```

---

## 5. CƠ CHẾ BẢO VỆ BANNER AD

### 5.1 Navigation Cooldown Guard (5s)

Khi user navigate nhanh giữa các màn hình, `BannerAdWidget` tự động kiểm tra:

```
Screen A → load banner → recordBannerLoad() → timer = T
Screen B (2s sau) → canLoadBanner() → "cooldown active, remaining=3s" → ẨN widget
Screen C (6s sau) → canLoadBanner() → "load allowed, timer reset" → load banner
```

Ngưỡng cooldown: **5 giây** (thay đổi trong `AdManager._bannerLoadCooldown`)

### 5.2 AdMob — `_admobIsTopRoute` Per-Widget Guard

**Vấn đề cũ:** `bannerVisible` là global `ValueNotifier` dùng chung cho tất cả `BannerAdWidget`. Khi set `bannerVisible=true`, cả ScreenA lẫn ScreenB đều react và cùng render `AdWidget` trên cùng một `BannerAd` object → crash "AdWidget already in tree".

**Giải pháp:** Mỗi `BannerAdWidget` instance có riêng `_admobIsTopRoute ValueNotifier<bool>` (khởi tạo `false`). Chỉ render `AdWidget` khi cả 2 flag đều `true`:

```
_admobIsTopRoute (PER-WIDGET) AND bannerVisible (GLOBAL lifecycle)
```

**RouteAware hook → `_admobIsTopRoute` lifecycle:**

| Hook | Thực thi | `_admobIsTopRoute` | Ghi chú |
|------|----------|-------------------|---------|
| `didPush()` | postFrameCallback | `false → true` | Defer tránh markNeedsBuild-during-build |
| `didPushNext()` | Immediate | `true → false` | Screen bị che, gỡ AdWidget ngay |
| `didPop()` | Immediate | `true → false` | Screen đang pop, gỡ AdWidget trước khi screen dưới mount AdWidget |
| `didPopNext()` | postFrameCallback | `false → true` | Defer để ScreenB đã gỡ AdWidget trước |

**Tại sao `false` và `postFrame` quan trọng:**
- `=false` (immediate): remove AdWidget khỏi tree NGAY trong frame hiện tại
- `=true` (postFrameCallback): add AdWidget SAU khi frame trước hoàn chỉnh → đảm bảo không bao giờ có 2 AdWidget cùng tồn tại
- Khởi tạo `false`: first build là SizedBox placeholder (1 frame, không thấy được) → tránh conflict với screen đang để lại AnimWidget

**bannerVisible (global) vẫn được giữ** — chỉ dùng cho lifecycle background/foreground:
```
App → Background: bannerVisible=false (ẩn toàn bộ)
App → Foreground: bannerVisible=true  (hiện lại)
```

### 5.3 AppLovin — `MaxAdView` Luôn Mounted

```
❌ Sai (deadlock): isLoaded=false → không render MaxAdView → MaxAdView không mount → callback không fire
✅ Đúng (Stack): MaxAdView luôn được mount → callback fire → isLoaded=true → shimmer ẩn
```

AppLovin **không gặp** vấn đề double-view vì `MaxAdView` là **native view được reuse** (không phải Dart object mới mỗi lần). `_admobIsTopRoute` không được dùng cho AppLovin path.

### 5.4 Click Tracking

Mỗi banner click → `AdSafetyConfig.recordAdClick()` → track `clicks/min`.
SDK (AppLovin/AdMob) xử lý click ở platform level — app không thể block, chỉ có thể monitor.

---

## 6. ADMOB — CƠ CHẾ GUARD CHI TIẾT

### 6.1 App Open — 4 Lớp Chặn

```dart
// Lớp 1: Mutex loading
if (_isAppOpenLoading) → skip (đang request mạng rồi)

// Lớp 2: Cache validity (4 giờ)
if (ad != null && age < 4h) → "ad still valid, no need to reload"

// Lớp 3: isShowing guard
if (_isAppOpenShowing) → skip (đang hiện rồi)

// Lớp 4: AdSafety 7-check
AdSafety.canShowFullscreenAd() → throttle / cap / CTR check
```

### 6.2 Interstitial — 3 Lớp Chặn

```dart
// Lớp 1: In-memory guard
if (_interstitialAd != null) → "ad already in memory, no need to reload"

// Lớp 2: Mutex loading
if (_isInterLoading) → "already loading, skip request"

// Lớp 3: _isInterstitialShowing guard (không show App Open khi Inter đang hiện)
if (_isInterstitialShowing) → showAppOpenAdOnResume skips entirely
```

### 6.3 Rewarded — 3 Lớp Chặn

```dart
// Lớp 1: In-memory guard
if (_rewardedAd != null) → "ad already in memory, no need to reload"

// Lớp 2: Mutex loading
if (_isRewardedLoading) → "already loading, skip request"

// Lớp 3: _isRewardedShowing guard (không show App Open khi Rewarded đang hiện)
if (_isRewardedShowing) → showAppOpenAdOnResume skips entirely
```

---

## 7. APPLOVIN MAX — CƠ CHẾ GUARD CHI TIẾT

### 7.1 App Open — AppLovin Specific

```dart
// Load guard
if (_isMaxAppOpenReady) → ad đã sẵn sàng (AppLovin preload xong)

// Show guard
if (!_isMaxAppOpenReady) → "Ad not ready" → onAdDismiss(false)
if (_isMaxAppOpenShowing) → skip

// Dismissed callback (từ listener, không qua onAdDismiss)
onAdHiddenCallback → _onAppOpenDismissed?.call(true) → "✅ Ad dismissed by user"
```

### 7.2 Interstitial — AppLovin Specific

```dart
// Guard mới (tránh spam load khi ad đang sẵn sàng)
if (_isMaxInterReady) → "⏭️ ad already ready, no need to reload"
// Sau khi user dismiss → _isMaxInterReady = false → có thể load lại bình thường
```

### 7.3 Rewarded — AppLovin Specific

```dart
// Callback chính từ listener:
onAdLoadedCallback   → _isMaxRewardedReady = true
onAdHiddenCallback   → _isMaxRewardedReady = false → auto preload next
onUserEarned...      → onEarnedReward(true)
```

---

## 8. AD SAFETY — 12 BIỆN PHÁP CHỐNG INVALID TRAFFIC

### 8.1 `canShowFullscreenAd()` — 7 Checks theo thứ tự

| # | Check | Giới hạn | Log khi fail |
|---|-------|----------|--------------|
| 1 | Suspicious pause | Dynamic: 30m→1h→2h→4h→8h | `🛡️ Suspended, remaining=Xs` |
| 2 | Session duration | Phải > 10s từ khi app mở | `🛡️ Session too young` |
| 3 | Session cap | ≤ 6 fullscreen/session | `🛡️ Session limit: X/6` |
| 4 | Hourly cap | ≤ 3 fullscreen/giờ | `🛡️ Hourly cap: X/3` |
| 5 | Daily limit | ≤ 5 fullscreen/ngày (persistent) | `🛡️ Daily limit: X/5` |
| 6 | Throttle | ≥ 60s giữa 2 fullscreen | `🛡️ Throttle: wait Xs` |
| 7 | CTR anomaly | CTR ≤ 30% (khi ≥ 5 impressions) | `⚠️ SUSPICIOUS: CTR` |

### 8.2 `canShowAppOpenOnResume()` — 3 Checks

| # | Check | Log khi fail |
|---|-------|--------------|
| 1 | Cold start skip | `🛡️ Skipping App Open on cold start` |
| 2 | Background quá ngắn < 5s | `🛡️ Resume too fast (Xms)` |
| 3 | Rapid resume > 3/min | `🛡️ Rapid resume detected: X resumes/min` |

### 8.3 Progressive Suspension

```
Vi phạm 1 → Pause 30 phút
Vi phạm 2 → Pause 1 giờ
Vi phạm 3 → Pause 2 giờ
Vi phạm 4 → Pause 4 giờ
Vi phạm 5+ → Pause 8 giờ (max 24 giờ)
```

---

## 9. LOG REFERENCE — ĐỌC LOG ĐỂ DEBUG

> 📌 Tất cả logs ad đều có prefix **`[AdMob]`** hoặc **`[AppLovin]`** để phân biệt provider.

### 9.1 Log tốt (cần thấy)

```
✅ Ad Loaded successfully                          ← Ad tải thành công
✅ Ad Shown full screen                            ← Ad hiện lên
✅ Ad Dismissed by user                            ← Ad bị tắt bởi user (THẬT)
📊 Ad SHOWN | session=X/6 | hourly=X/3 | daily=X/5 ← AdSafety counts
canLoadBanner ✅ load allowed, timer reset          ← Banner được load
```

### 9.2 Log RouteAware Banner — [AdMob]

```
RouteAware.didPush() ▶️ [AdMob] scheduling _admobIsTopRoute=true via postFrameCallback
RouteAware.didPush() postFrame ▶️ [AdMob] _admobIsTopRoute=true (AdWidget now in tree)
RouteAware.didPushNext() ⏸️ [AdMob] _admobIsTopRoute=false (hiding AdWidget)
RouteAware.didPop() ⏹️ [AdMob] _admobIsTopRoute=false (removing AdWidget immediately)
RouteAware.didPopNext() ▶️ [AdMob] scheduling _admobIsTopRoute=true via postFrameCallback
RouteAware.didPopNext() postFrame ▶️ [AdMob] _admobIsTopRoute=true (top route popped)
```

### 9.3 Log RouteAware Banner — [AppLovin]

```
RouteAware.didPush() ▶️ [AppLovin] scheduling Banner RESUME via postFrameCallback
RouteAware.didPush() postFrame ▶️ [AppLovin] bannerAutoRefreshEnabled=true
RouteAware.didPushNext() ⏸️ [AppLovin] Banner PAUSED (route covered by new push)
RouteAware.didPopNext() ▶️ [AppLovin] Banner RESUMED (top route popped)
RouteAware.didPop() ⏹️ route containing banner is popping
```

### 9.4 Log Warning (quan sát)

```
⏭️ already loading, skip request           ← Mutex đang lock (tốt)
⏭️ ad already in memory, no need to reload ← Cache hit (rất tốt)
⏭️ ad still valid (< 4h), no need to reload← 4h cache hit (tốt)
⏭️ ad already ready, no need to reload     ← AppLovin guard (tốt)
🔄 Ad blocked/skipped before show          ← Safety chặn, KHÔNG phải dismissed
canLoadBanner ⏭️ cooldown active           ← Navigation quá nhanh
```

### 9.5 Log cần chú ý

```
🛡️ Throttle: wait Xs           ← Đang trong cooling down — bình thường
🛡️ Hourly cap: 3/3             ← Đã đạt giới hạn giờ — bình thường
🛡️ Skipping App Open on cold start ← Lần resume đầu tiên — bình thường
🛡️ Resume too fast (Xms)       ← User vào/ra quá nhanh — bình thường
⚠️ SUSPICIOUS                  ← CTR hoặc click spam — cần kiểm tra
```


---

## 10. CHECKLIST TRƯỚC KHI RELEASE

- [ ] Đổi tất cả ad unit ID từ test → production trong `k/k.dart`
- [ ] Đổi `kTestDeviceIds` về `[]` (hoặc chỉ giữ thiết bị QA)
- [ ] Kiểm tra `kVipDeviceGaids` đúng danh sách
- [ ] Confirm `kIsEnableAdmob` đúng với provider muốn dùng
- [ ] Kiểm tra `AndroidManifest.xml` có đúng AdMob Application ID
- [ ] Test trên real device (emulator không phục vụ ad thật)
- [ ] Xem log không có dòng `⚠️ SUSPICIOUS` bất thường
- [ ] Kiểm tra `daily=X/5` tăng đúng sau mỗi phiên test

---

## 11. TROUBLESHOOTING

### "AdWidget is already in the Widget tree" (AdMob Banner)
**Nguyên nhân:** `bannerVisible` là global ValueNotifier. Khi set `=true`, tất cả `BannerAdWidget` đang mount đều rebuild và cố render `AdWidget` trên cùng một `BannerAd` object.
**Fix:** `_admobIsTopRoute` per-widget flag (khởi tạo `false`). `didPushNext()/didPop()` set `=false` immediate. `didPush()/didPopNext()` set `=true` via `addPostFrameCallback` → đảm bảo chỉ 1 AdWidget trong tree mỗi lúc.

### "setState() or markNeedsBuild() called during build"
**Nguyên nhân:** `RouteObserver.subscribe()` gọi `didPush()` SYNCHRONOUSLY bên trong `_firstBuild`. Set `ValueNotifier.value` ở đây trigger `markNeedsBuild()` during build frame.
**Fix:** Wrap tất cả `ValueNotifier.value=` trong `didPush()` bằng `addPostFrameCallback`.

### Banner bị stuck shimmer (AppLovin)
**Nguyên nhân:** `MaxAdView` không được mount vào widget tree trước khi `isLoaded=true`.
**Fix:** Code đã fix bằng `Stack` — MaxAdView luôn mounted, shimmer overlay lên trên.

### App Open show cùng lúc Interstitial
**Nguyên nhân:** Resume lifecycle fire trong khi Inter đang fullscreen.
**Fix:** `_isInterstitialShowing = true` khi show Inter, guard trong `showAppOpenAdOnResume`.

### Log `✅ Ad dismissed` khi ad chưa từng show
**Nguyên nhân:** `onAdDismiss(true)` bị gọi ở các nhánh early-exit.
**Fix:** Tất cả nhánh bị block gọi `onAdDismiss(false)`. Resume callback phân nhánh `wasActuallyShown`.

### Spam `loadInterstitial` khi user navigate nhanh
**Nguyên nhân:** Mỗi screen `initState` gọi `loadInterstitial`.
**Fix AdMob:** `_interstitialAd != null` guard. **Fix AppLovin:** `_isMaxInterReady` guard.

### Banner load quá nhiều lần
**Nguyên nhân:** User navigate nhanh qua nhiều màn hình.
**Fix:** `canLoadBanner()` cooldown 5s trong `AdManager`.

---

## 12. PHIÊN BẢN VÀ THAY ĐỔI

| Ngày | Version | Thay đổi |
|------|---------|----------|
| 20260321 | v1 | Port từ Kotlin AdManager.kt — baseline |
| 20260321 | v2–v12 | 12 iterations: observer, adaptive banner, rewarded, mutex, cache, deadlock fix, guards |
| 20260322 | v13–v17 | Provider labels, setState fix, AdWidget-in-tree fix (push+pop), document update |
| **20260323** | **v18** | **SDK Package `applovin_admob_sdk` — 39 bug fixes qua 9 audit rounds** |

---

## 13. SDK INTERNALS — FLOW CHI TIẾT

### 13.1 App Open Ad — Complete Flow

```
┌─────────────── LOAD ───────────────┐
│ loadAppOpenAd()                    │
│ ├─ VIP? → skip                     │
│ ├─ No internet? → skip             │
│ ├─ 15min cooldown? → skip          │
│ ├─ _isAppOpenLoading? → skip       │
│ │                                  │
│ ├─ [AdMob]                         │
│ │  ├─ _appOpenAd cached <4h? → OK  │
│ │  ├─ >4h? → dispose + reload      │  ← Fix #24
│ │  └─ AppOpenAd.load() → cache     │
│ │                                  │
│ └─ [AppLovin]                      │
│    └─ AppLovinMAX.loadAppOpenAd()  │
│    └─ onAdLoadedCallback → ready   │
│                                    │
│ ★ First ad loaded → trigger        │
│   loadInterstitial()+loadRewarded()│
└────────────────────────────────────┘

┌─────────────── SHOW ───────────────┐
│ showAppOpenAd(onAdDismiss)         │
│ ├─ VIP? → onAdDismiss(false)       │
│ ├─ already showing? → skip         │
│ ├─ bypassSafety=false?             │
│ │  └─ canShowFullscreenAd() check  │
│ │                                  │
│ ├─ [AdMob] ad.show()               │
│ │  ├─ onShowed → recordShown()     │
│ │  ├─ onDismissed → dispose+reload │
│ │  └─ onFailedToShow → reload      │  ← Fix Y
│ │                                  │
│ └─ [AppLovin] AppLovinMAX.show()   │
│    ├─ 10s timeout guard            │  ← Fix #17
│    ├─ onAdDisplayed → recording    │
│    └─ onAdHidden → reload          │
└────────────────────────────────────┘

┌─────────────── ON RESUME ──────────┐
│ didChangeAppLifecycleState(resumed)│
│ └─ showAppOpenAdOnResume()         │
│    ├─ splash active? → skip        │
│    ├─ inter/rewarded showing? → no │
│    ├─ canShowAppOpenOnResume()      │
│    │  ├─ cold start? → skip (1x)   │  ← Fix #15
│    │  ├─ <5s background? → skip    │
│    │  └─ >3 resumes/min? → skip    │
│    └─ showAppOpenAd(bypassSafety)  │  ← Fix #3
└────────────────────────────────────┘
```

### 13.2 Interstitial Ad — Complete Flow

```
┌─── AdScreen.showInterstitialAd() ──┐
│ ├─ disposed/unmounted? → false     │
│ ├─ canShowInterstitial() pre-check │  ← gồm safety + dialog guard
│ ├─ AdLoadingDialog (1s buffer)     │
│ │  └─ concurrent guard (_isShowing)│  ← Fix #22
│ └─ AdManager.showInterstitial()    │
│    ├─ _isInterstitialShowing=true  │  ← set TRƯỚC dialog (Fix 2)
│    ├─ canShowFullscreenAd() recheck│
│    ├─ [AdMob] ad.show()            │
│    │  ├─ dismiss → dispose+reload  │
│    │  └─ fail → reload             │  ← Fix #1
│    └─ [AppLovin] MAX.show()        │
│       └─ listener → callback       │
└────────────────────────────────────┘
```

### 13.3 Rewarded Ad — Complete Flow

```
┌─── AdScreen.showRewardedAd() ──────┐
│ ├─ VIP? → auto-reward onEarned(T)  │
│ ├─ canShowRewardedAd() pre-check   │
│ │  └─ fail? → TopToast + false     │
│ ├─ AdLoadingDialog (1s buffer)     │
│ └─ AdManager.showRewardedAd()      │
│    ├─ _isRewardedShowing=true EARLY│
│    ├─ canShowFullscreenAd() recheck│
│    ├─ [AdMob]                      │
│    │  ├─ ad.show(onUserEarned)     │
│    │  ├─ earned → callback(true)   │
│    │  ├─ dismissed w/o earn → false│
│    │  └─ fail → reload             │  ← Fix #2
│    └─ [AppLovin]                   │
│       ├─ onAdReceived → flow(true) │
│       └─ onHidden w/o reward       │
│          → flow(false) + reload    │
└────────────────────────────────────┘
```

### 13.4 Banner Ad — Complete Flow

```
┌─── BannerAdWidget mount ───────────┐
│ ├─ didChangeDependencies()         │
│ │  ├─ RouteAware subscribe         │
│ │  └─ _initBanner() (1 lần)       │
│ │     ├─ VIP? → SizedBox.shrink    │
│ │     ├─ no internet? → skip       │
│ │     ├─ 5s cooldown? → skip       │
│ │     ├─ [AdMob] loadAdmobBanner() │
│ │     └─ [AppLovin] preloaded      │
│ │                                  │
│ ├─ Route navigation:               │
│ │  didPushNext → pause/hide        │
│ │  didPopNext  → resume/show       │
│ │  didPop      → hide immediately  │
│ │                                  │
│ └─ App lifecycle:                  │
│    paused  → hide/pause refresh    │
│    resumed → show/resume refresh   │
│           → auto-reload on error   │  ← Fix #14
└────────────────────────────────────┘
```

---

## 14. FILL RATE OPTIMIZATION

| Cơ chế | Mô tả |
|--------|-------|
| **Sequential preload** | App Open load xong → trigger Inter + Rewarded load |
| **Auto-reload after dismiss** | Mọi ad type đều reload ngay khi user dismiss |
| **Auto-reload after show-fail** | Mọi ad type đều reload khi hiện lỗi |
| **5-min retry timer** | Tự động check + fill ad slots trống mỗi 5 phút |
| **4h expiry reload** | AdMob App Open hết hạn 4h → tự dispose + load mới |
| **Resume banner reload** | Banner tự load lại khi resume nếu trước đó bị lỗi |
| **Error cooldown 15min** | Tránh spam server khi load liên tục thất bại |

---

## 15. MEMORY LEAK PREVENTION

| Cơ chế | Mô tả |
|--------|-------|
| **fullScreenContentCallback = null** | Set null TRƯỚC dispose để tránh late callback |
| **EventBus clearAll()** | Xoá listeners trong destroy() |
| **Observer paired** | addObserver/removeObserver đúng cặp |
| **ValueNotifier reset** | Reset value, KHÔNG dispose (singleton lifetime) |
| **_cleanupOldAds()** | Auto-dispose khi initialize() gọi lại không có destroy() |
| **Pending callback flush** | Tất cả pending callbacks fire(false) trước khi null trong destroy() |
| **Static state reset** | AdLoadingDialog.resetState(), AdSafetyConfig.resetForReinit() |
| **Expired ad dispose** | App Open >4h bị dispose trước khi load mới |

---

## 16. DESTROY / REINIT SAFETY

```
destroy() hoàn tất reset:
  ✅ AdMob ads: callback=null → dispose → null
  ✅ Pending callbacks: fire(false) → null
  ✅ AppLovin state flags: tất cả reset false
  ✅ Loading flags: _isInterLoading, _isRewardedLoading, _isAppOpenLoading
  ✅ Showing flags: _isInterstitialShowing, _isRewardedShowing, _isAppOpenShowing
  ✅ Error cooldowns: reset → 0
  ✅ Banner state: route pause, splash, load cooldown
  ✅ ValueNotifiers: reset values (not disposed)
  ✅ AdSafetyConfig: full reinit (cold start restored)
  ✅ EventBus: clearAll()
  ✅ Retry timer: stopped
  ✅ Lifecycle observer: removed + flag reset
  ✅ AdLoadingDialog: _isShowing reset
  ✅ _isInitializing = false (Fix #39)
  ✅ _initialized = false

initialize() an toàn:
  ✅ Nếu _initialized=true → auto _cleanupOldAds() trước
  ✅ _cleanupOldAds reset banner ValueNotifiers (Fix #37)
  ✅ Concurrent init guard (_isInitializing mutex, Fix #36)
  ✅ SDK init wrapped in try-catch (Fix #38)
  ✅ Observer tự re-add nếu chưa có
  ✅ VIP GAIDs clear trước addAll (không accumulate)
  ✅ SafeLogger.setEnabled EARLY (Fix #34)
```

---

## 17. AUDIT SUMMARY — 54 BUGS FIXED (20 ROUNDS)

| Loại | Số lượng |
|------|----------|
| 🔴 Critical crash | 5 (#29, #32, #33, #38, #40) |
| 🔴 High severity | 3 (#36, #37, #41) |
| 🟡 Medium | 20+ |
| 🟢 Logic/edge case | 26+ |
| **Tổng** | **54** |
