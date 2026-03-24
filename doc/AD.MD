# 📊 TÍCH HỢP QUẢNG CÁO (AdMob + AppLovin MAX) — FLUTTER

> Version: 20260324-v21 | SDK: `applovin_admob_sdk` v1.0.14 (pub.dev)
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
> 📋 Đọc hết phần này trước khi bắt đầu. Làm từng bước theo thứ tự, **KHÔNG skip bước nào**.

### Mục tiêu cuối cùng

Sau khi hoàn thành 7 step, app bạn sẽ có:
- ✅ **App Open Ad** hiện khi mở app lần đầu (có loading dialog 1s)
- ✅ **App Open Ad** tự hiện khi user quay lại app từ background
- ✅ **Banner Ad** nằm ở đầu/cuối màn hình, tự pause/resume theo navigation
- ✅ **Interstitial Ad** hiện trước khi chuyển màn hình (có loading dialog 1s)
- ✅ **Rewarded Ad** hiện khi user muốn nhận thưởng
- ✅ **12 cơ chế bảo vệ** chống invalid traffic (tự động, không cần code thêm)

---

### 📁 Tổng quan file cần sửa

| # | File | Việc cần làm |
|---|------|-------------|
| 1 | `pubspec.yaml` | Thêm 2 dòng dependency |
| 2 | `android/app/build.gradle.kts` | Thêm `minSdk`, `buildConfig`, 2 dòng implementation |
| 3 | `android/app/src/main/AndroidManifest.xml` | Thêm 3 permission + 1 meta-data |
| 4 | `lib/main.dart` | Tạo navigatorKey, đăng ký SDK, thêm observers |
| 5 | `lib/splash_screen.dart` | Tạo mới — nơi init SDK + show App Open Ad |
| 6 | `lib/home_screen.dart` | Kế thừa `AdScreen` thay vì `StatefulWidget` |
| 7 | *(Không cần code)* | App Open resume tự động hoạt động |

---

### STEP 1 / 7 — Thêm Dependencies

> **Tại sao:** SDK quảng cáo là 1 package riêng trên pub.dev. Bạn cần khai báo để Flutter tải về.

**📂 Mở file:** `pubspec.yaml` (ở thư mục gốc project)

**📝 Tìm mục `dependencies:` rồi thêm 2 dòng:**

```yaml
dependencies:
  flutter:
    sdk: flutter
  # ... các package khác của bạn ...

  # ✅ THÊM 2 DÒNG NÀY:
  applovin_admob_sdk: ^1.0.14
  gma_mediation_applovin: ^1.0.0  # bỏ dòng này nếu chỉ dùng AdMob
```

**▶️ Chạy lệnh:**
```bash
flutter pub get
```

**✅ Kiểm tra thành công:** Terminal hiện `Got dependencies!` và KHÔNG có dòng đỏ.

**❌ Nếu lỗi:** Kiểm tra thụt lề (phải dùng 2 dấu cách, KHÔNG dùng tab).

---

### STEP 2 / 7 — Cấu hình Android Gradle

> **Tại sao:** SDK cần `minSdk >= 21` (Android 5.0+) và `buildConfig = true` để hoạt động.

**📂 Mở file:** `android/app/build.gradle.kts`

**📝 Sửa/thêm trong block `android { }` :**

```kotlin
android {
    // ... compileSdk, namespace, etc. ...

    defaultConfig {
        // ✅ Đảm bảo minSdk >= 21 (nếu đang < 21 thì sửa lên)
        minSdk = 21
        // ... targetSdk, versionCode, etc. ...
    }

    // ✅ THÊM block này nếu chưa có:
    buildFeatures {
        buildConfig = true
    }
}
```

**📝 Tìm block `dependencies { }` (nằm NGOÀI block `android { }`) rồi thêm:**

```kotlin
dependencies {
    // ... các dòng khác ...

    // ✅ THÊM 2 DÒNG NÀY:
    implementation("com.google.ads.mediation:applovin:13.2.0.1")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
}
```

**▶️ Kiểm tra:** Chạy `flutter build apk --debug` — phải thành công.

---

### STEP 3 / 7 — Cấu hình AndroidManifest.xml

> **Tại sao:** Google yêu cầu khai báo AD_ID permission và AdMob App ID trong manifest.

**📂 Mở file:** `android/app/src/main/AndroidManifest.xml`

**📝 Thêm 3 permission TRƯỚC tag `<application>` :**

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- ✅ THÊM 3 DÒNG NÀY (trước <application>) -->
    <uses-permission android:name="com.google.android.gms.permission.AD_ID" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application
        android:label="..."
        ...>

        <!-- ✅ THÊM BLOCK NÀY (trong <application>, trước </application>) -->
        <meta-data
            android:name="com.google.android.gms.ads.APPLICATION_ID"
            android:value="ca-app-pub-XXXXXXXXXXXXXXXX~XXXXXXXXXX" />
        <!--
            ⚠️ THAY "ca-app-pub-XXX~XXX" bằng AdMob App ID thật của bạn.
            ⚠️ Lấy ID ở: https://admob.google.com → Apps → App settings
            ⚠️ KHÔNG thêm applovin.sdk.key ở đây — SDK Key truyền qua code Dart
        -->

        <!-- ... activity, intent-filter, etc. ... -->
    </application>
</manifest>
```

**✅ Kiểm tra:** Build lại `flutter build apk --debug` thành công.

---

### STEP 4 / 7 — Đăng ký Navigator Key — `main.dart`

> **Tại sao:** SDK cần `navigatorKey` để:
> 1. Hiện loading dialog 1s trước mỗi ad fullscreen
> 2. Hiện App Open Ad khi user quay lại app từ background
> 3. Banner tự pause/resume khi chuyển màn hình (qua `adRouteObserver`)
>
> ⛔ **Nếu bỏ qua step này:** Banner crash khi navigate, App Open resume không có dialog.

**📂 Mở file:** `lib/main.dart`

**📝 Sửa file theo mẫu sau (chú ý các dòng có ✅):**

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart'; // ✅ THÊM

// ✅ THÊM: Tạo navigatorKey — biến GLOBAL, đặt NGOÀI class
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ THÊM: Đăng ký navigatorKey cho SDK — gọi TRƯỚC runApp()
  AdManager().setNavigatorKey(navigatorKey);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My App',

      // ✅ THÊM 3 dòng sau vào MaterialApp:
      navigatorKey: navigatorKey,               // Để SDK show dialog
      navigatorObservers: [
        adRouteObserver,                        // Banner pause/resume
        AdScreenRouteLogger(),                  // Log navigation (debug)
      ],

      home: const SplashScreen(),               // ✅ Điểm vào là SplashScreen
    );
  }
}
```

> 💡 **Nếu dùng GetX:** Thay `MaterialApp` bằng `GetMaterialApp`, tương tự:
> ```dart
> GetMaterialApp(
>   navigatorKey: navigatorKey,
>   navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
>   home: const MyApp(),
> )
> ```

**▶️ Kiểm tra:** Chạy app, mở **Logcat/Console**, tìm 2 dòng sau:
```
[AdManager] setNavigatorKey: registered ✅
[AdScreen~Router] ➡️ PUSH: / (from: null)
```
Nếu thấy → Step 4 thành công. Nếu không → kiểm tra `navigatorKey` truyền đúng chưa.

---

### STEP 5 / 7 — Tạo Splash Screen (Nơi init SDK + Show App Open Ad)

> **Tại sao:** SDK cần 1-3 giây để khởi tạo + tải ad. Splash screen là nơi duy nhất phù hợp
> để chờ quá trình này mà user không thấy lag.
>
> ⚠️ **QUAN TRỌNG:** `AdManager().initialize()` **BẮT BUỘC gọi ở SplashScreen**,
> KHÔNG được gọi trong `main()`. Lý do: EventBus listener phải đăng ký TRƯỚC khi `initialize()` fire event.

**📂 Tạo file mới:** `lib/splash_screen.dart`

**📝 Copy toàn bộ code sau:**

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

    // ── Bước A: Đánh dấu splash đang active ──
    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // ── Bước B: Skip ad nếu hot restart (đã vào app rồi) ──
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigateHome());
      return;
    }

    // ── Bước C: Hard cap 8s — nếu load quá lâu, vào home luôn ──
    _hardCapTimer = Timer(const Duration(seconds: 8), () => _navigateHome());

    // ── Bước D: Lắng nghe EventBus — nhận kết quả init ──
    // ⚠️ PHẢI đăng ký listener TRƯỚC khi gọi initialize()
    _eventListener = (event) {
      if (event.value) {
        // SDK init thành công → tải App Open Ad
        _loadAndShowAppOpenAd();
      } else {
        // SDK init thất bại → vào home luôn
        _navigateHome();
      }
    };
    SimpleEventBus().listen(_eventListener!);

    // ── Bước E: Gọi initialize() — chờ postFrameCallback ──
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().initialize(
        config: const AdConfig(
          // ⚠️ ĐỔI provider ở đây: .appLovin hoặc .admob
          provider: AdProvider.appLovin,
          admob: AdMobConfig(
            bannerId: 'ca-app-pub-3940256099942544/6300978111',
            interstitialId: 'ca-app-pub-3940256099942544/1033173712',
            appOpenId: 'ca-app-pub-3940256099942544/9257395921',
            rewardedId: 'ca-app-pub-3940256099942544/5224354917',
          ),
          appLovin: AppLovinConfig(
            sdkKey: 'YOUR_86_CHAR_SDK_KEY',   // ⚠️ THAY bằng SDK key thật
            bannerId: 'YOUR_BANNER_ID',        // ⚠️ THAY bằng ID thật
            interstitialId: 'YOUR_INTER_ID',   // ⚠️ THAY bằng ID thật
            appOpenId: 'YOUR_APP_OPEN_ID',     // ⚠️ THAY bằng ID thật
            rewardedId: 'YOUR_REWARDED_ID',    // ⚠️ THAY bằng ID thật
          ),
          vipDeviceGaids: [],        // GAID của thiết bị VIP (không hiện ad)
          loadingBufferMs: 1000,     // Thời gian hiện loading dialog (ms)
          adNotReadyMessage: 'Ad chưa sẵn sàng, vui lòng thử lại.',
          adLoadingMessage: 'Đang tải…',
        ),
        onComplete: (success, gaid) {
          SafeLogger.d('Splash', 'SDK ready=$success, GAID=$gaid');
        },
      );
    });
  }

  /// Tải App Open Ad → nếu thành công thì hiện loading dialog + show ad
  void _loadAndShowAppOpenAd() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_hasNavigated) return; // đã navigate rồi (ví dụ timeout 8s)
      if (loaded) {
        if (!mounted) { _navigateHome(); return; }
        // Hiện loading dialog 1 giây → rồi show ad
        AdLoadingDialog.showAdBuffer(context, onComplete: () {
          if (!mounted) { _navigateHome(); return; }
          _hardCapTimer?.cancel();
          AdManager().showAppOpenAd(
            bypassSafety: true,     // Splash luôn show, bỏ qua throttle
            onAdDismiss: (_) => _navigateHome(),
          );
        });
      } else {
        _navigateHome(); // Load thất bại → vào home
      }
    });
  }

  /// Chuyển sang HomeScreen — chỉ được gọi ĐÚNG 1 LẦN
  void _navigateHome() {
    if (_hasNavigated) return;
    _hasNavigated = true;
    _hardCapTimer?.cancel();
    if (_eventListener != null) {
      SimpleEventBus().remove(_eventListener!);
      _eventListener = null;
    }
    AdManager().markSplashInactive();
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
    // Bạn có thể thay bằng logo app + animation
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
```

**▶️ Kiểm tra log (theo thứ tự):**
```
1. [AdManager] ###init called, provider=AdProvider.appLovin
2. [AdManager] ###init completed
3. [AdManager] loadAppOpenAd [AppLovin] 🔄 ...
4. [AdManager] ✅ [AppLovin] App Open Ad Loaded
5. [AdLoadingDialog] showAdBuffer: showing dialog, bufferMs=1000
6. [AdManager] ✅ [AppLovin] App Open Ad Shown
7. [AdManager] ✅ [AppLovin] App Open Ad Dismissed
8. [AdManager] markSplashInactive
```

**❌ Nếu không thấy log #1:** `initialize()` chưa được gọi — kiểm tra `postFrameCallback`.
**❌ Nếu thấy log #1 nhưng không có #2:** SDK key hoặc network bị sai.
**❌ Nếu thấy #4 nhưng không có #5:** Thiếu `navigatorKey` ở Step 4.

---

### STEP 6 / 7 — Tạo màn hình có Ads (kế thừa `AdScreen`)

> **Tại sao dùng `AdScreen`:** Thay vì `StatefulWidget`, bạn kế thừa `AdScreen` để SDK tự:
> - Preload interstitial khi màn hình mở
> - Quản lý banner lifecycle (pause khi navigate, resume khi quay lại)
> - Cung cấp sẵn hàm `showInterstitialAd()`, `showRewardedAd()`, `buildBanner()`

**📂 Mở file:** `lib/home_screen.dart` (hoặc bất kỳ màn hình nào cần ad)

**📝 Thay đổi 2 chỗ:**

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// TRƯỚC (không có ad):
//   class HomeScreen extends StatefulWidget { ... }
//   class _HomeScreenState extends State<HomeScreen> { ... }
//
// SAU (có ad):
//   class HomeScreen extends AdScreen { ... }           ← đổi ở đây
//   class _HomeScreenState extends AdScreenState<HomeScreen> { ... }  ← và đây
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class HomeScreen extends AdScreen {  // ← ĐỔI: StatefulWidget → AdScreen
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {  // ← ĐỔI: State → AdScreenState

  /// Ví dụ 1: Hiện Interstitial trước khi chuyển màn hình
  void _goToNextScreen() {
    // SDK tự: pre-check → loading dialog 1s → show ad → gọi onDone
    showInterstitialAd(onDone: (shown) {
      // shown=true: ad đã hiện xong | shown=false: ad không sẵn sàng hoặc bị throttle
      // Dù shown=true hay false, luôn navigate (UX tốt hơn)
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DetailScreen()));
    });
  }

  /// Ví dụ 2: Hiện Rewarded Ad — user xem ad để nhận thưởng
  void _watchAdForCoins() {
    showRewardedAd(onEarnedReward: (earned) {
      if (!mounted) return;
      if (earned) {
        // ✅ User xem hết ad → TRẢ THƯỞNG ở đây
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('+10 coins!')),
        );
      }
      // earned=false → ad bị skip / không sẵn sàng (SDK tự show TopToast thông báo)
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // ── Banner Ad ──
          // buildBanner() là hàm có sẵn từ AdScreenState
          // Banner tự load, tự pause khi navigate, tự resume khi quay lại
          buildBanner(),

          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    onPressed: _goToNextScreen,
                    child: const Text('Go to Detail (Interstitial Ad)'),
                  ),
                  const SizedBox(height: 16),
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

> 📌 **Ghi nhớ:**
> - `AdScreenState` tự gọi `loadInterstitial()` trong `initState`. Nếu SDK chưa init xong → SDK bỏ qua (không crash).
> - `buildBanner()` chỉ cần gọi 1 lần trong `build()`. SDK quản lý toàn bộ lifecycle.
> - `showInterstitialAd()` và `showRewardedAd()` đã tích hợp sẵn loading dialog 1s.

---

### STEP 7 / 7 — App Open On Resume (TỰ ĐỘNG — Không cần code)

> **Tại sao không cần code:** SDK đã đăng ký `WidgetsBindingObserver` bên trong.
> Khi user rời app rồi quay lại, SDK tự xử lý toàn bộ flow:

```
User nhấn Home (app vào background)
  → Đợi ≥ 5 giây
  → User quay lại app
  → SDK check: canShowAppOpenOnResume()
     ├── Nếu OK  → Hiện AdLoadingDialog 1s → Show App Open Ad
     └── Nếu KHÔNG (throttle/cold start/…) → Log lý do → Skip
```

> ⚠️ **Điều kiện bắt buộc:** Step 4 phải hoàn thành (có `navigatorKey`).
> Nếu thiếu → resume CÓ ad nhưng KHÔNG có loading dialog.

**▶️ Kiểm tra:**
1. Chạy app, đợi qua splash vào home
2. Nhấn Home (app vào background), đợi 60 giây
3. Mở lại app
4. Xem log:
```
[AdManager] ProcessLifecycle ▶️ App came to FOREGROUND
[AdManager] ▶️ showAppOpenAdOnResume: showing loading dialog...
[AdLoadingDialog] showAdBuffer: showing dialog, bufferMs=1000
[AdManager] ✅ [AppLovin] App Open Ad Shown
```

**❌ Nếu thấy `🛡️ Skipping on cold start`:** Đây là bình thường — lần resume đầu tiên luôn bị skip.
**❌ Nếu thấy `🛡️ Throttle: wait Xs`:** Đây là bình thường — cần đợi 60s giữa 2 fullscreen ad.

---

### 🎉 HOÀN THÀNH!

Nếu bạn hoàn thành đủ 7 step, app sẽ có đầy đủ:

| Tính năng | Trạng thái |
|-----------|-----------|
| App Open Ad (splash) | ✅ Tự động |
| App Open Ad (resume) | ✅ Tự động |
| Banner Ad | ✅ `buildBanner()` |
| Interstitial Ad | ✅ `showInterstitialAd()` |
| Rewarded Ad | ✅ `showRewardedAd()` |
| Loading Dialog 1s | ✅ Tự động trước mọi fullscreen |
| 12 Safety Guards | ✅ Tự động, không cần config |

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
| **20260324** | **v21** | **Rewrite Integration Guide cho fresher — thêm WHY, file map, troubleshoot per step** |
