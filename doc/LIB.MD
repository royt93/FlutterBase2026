# LIB.MD — Ad SDK Library Plan
_Version: 20260322-v1 | Author: roy93~_

---

## 1. KẾT LUẬN KHẢ THI

> **✅ Hoàn toàn khả thi** — nhưng cần refactor tầng config theo đúng convention pub.dev.
> Thời gian ước tính: **3–5 ngày** nếu full-time. Complexity: **Medium-High**.

### Lý do khả thi
- Toàn bộ ad logic đã **self-contained** trong `lib/mckimquyen/ad/` — không phụ thuộc vào business logic app
- `AdManager` là **singleton thuần**, không coupling với GetX hay bất kỳ state management cụ thể nào
- `BannerAdWidget`, `AdScreen`, `AdSafetyConfig` đều **stateless dependencies** — dễ tách
- Đã xử lý xong 2 provider (AdMob + AppLovin) → **dual-provider pattern** là USP của lib này trên pub.dev

### Thách thức chính
- **Ad IDs/Config (`k.dart`)**: Hiện hardcode constants → phải đổi sang runtime injection (constructor/initializer)
- **`BaseStatefulState`**: `AdScreenState` kế thừa nó → phải bỏ dependency hoặc expose nó
- **`connection_notifier`**: Dependency cần evaluate giữ hay implement lại
- **pub.dev requirements**: README, example app, API docs, license, score ≥ 70

---

## 2. KIẾN TRÚC THƯ VIỆN

### Tên package đề xuất
```
ad_sdk
```
_(pub.dev convention: lowercase + underscore → `adSDK` → `ad_sdk`)_

### Cấu trúc thư mục

```
ad_sdk/                             ← Package root
├── lib/
│   ├── ad_sdk.dart                 ← Barrel export
│   └── src/
│       ├── config/
│       │   └── ad_config.dart      ← AdConfig class (thay k.dart)
│       ├── core/
│       │   ├── ad_manager.dart     ← Singleton (giữ nguyên logic)
│       │   ├── ad_safety_config.dart
│       │   ├── ad_route_observer.dart
│       │   ├── ad_screen.dart
│       │   └── event_bus.dart
│       ├── utils/
│       │   ├── safe_logger.dart
│       │   └── ad_preferences.dart ← Rename từ app_preferences.dart
│       └── widget/
│           ├── banner_ad_widget.dart
│           ├── ad_loading_dialog.dart
│           └── shimmer_view.dart
├── example/                        ← Demo app (bắt buộc pub.dev)
│   ├── lib/
│   │   ├── main.dart
│   │   └── screens/
│   │       ├── home_screen.dart    ← Banner + Inter demo
│   │       └── history_screen.dart ← Rewarded demo
│   ├── android/
│   └── pubspec.yaml
├── test/                           ← Unit tests
│   ├── ad_config_test.dart
│   └── ad_safety_test.dart
├── pubspec.yaml
├── README.md
├── CHANGELOG.md
└── LICENSE
```

---

## 3. THAY ĐỔI LỚN KHI REFACTOR

### 3.1 Thay `k.dart` bằng `AdConfig` class (BREAKING CHANGE LỚN NHẤT)

**Hiện tại (hardcode):**
```dart
// k/k.dart — constants cứng trong lib
const bool kIsEnableAdmob = false;
const String kAppLovinSdkKey = "e75FnQfS9X...";
```

**Sau refactor (runtime injection):**
```dart
// Người dùng library gọi trước khi runApp()
AdManager().initialize(
  config: AdConfig(
    provider: AdProvider.appLovin,   // hoặc AdProvider.admob
    appLovin: AppLovinConfig(
      sdkKey: "YOUR_SDK_KEY",
      bannerId: "YOUR_BANNER_ID",
      interstitialId: "YOUR_INTER_ID",
      appOpenId: "YOUR_APP_OPEN_ID",
      rewardedId: "YOUR_REWARDED_ID",
    ),
    admob: AdMobConfig(
      bannerId: "ca-app-pub-xxx/xxx",
      interstitialId: "ca-app-pub-xxx/xxx",
      appOpenId: "ca-app-pub-xxx/xxx",
      rewardedId: "ca-app-pub-xxx/xxx",
      testDeviceIds: ["HASH1", "HASH2"],
    ),
    vipDeviceGaids: ["gaid-1", "gaid-2"],
    loadingBufferMs: 1000,
    safetyConfig: AdSafetyConfig.defaults(),  // tunable
  ),
  onComplete: (success, gaid) { ... },
);
```

### 3.2 Bỏ `BaseStatefulState` dependency

**Hiện tại:**
```dart
abstract class AdScreenState<T extends AdScreen>
    extends BaseStatefulState<T> { ... }  // coupling với core lib
```

**Sau refactor:**
```dart
abstract class AdScreenState<T extends AdScreen>
    extends State<T> with WidgetsBindingObserver { ... }  // self-contained
```
→ Chuyển logic từ `BaseStatefulState` cần thiết vào `AdScreenState` trực tiếp.

### 3.3 `AdSafetyConfig` → configurable thay vì hardcode

```dart
// Cho phép override defaults:
AdSafetyConfig(
  maxFullscreenAdsPerDay: 5,
  maxFullscreenAdsPerHour: 3,
  minTimeBetweenFullscreenAds: const Duration(seconds: 60),
  minTimeAppOpenResume: const Duration(seconds: 5),
  // Anti-fraud
  suspiciousCtrThreshold: 0.30,
  maxClicksPerMinute: 3,
)
```

### 3.4 Logger — tắt được trong production

```dart
// Người dùng có thể enable/disable
AdManager().setLogLevel(AdLogLevel.none);    // production
AdManager().setLogLevel(AdLogLevel.verbose); // debug
```

---

## 4. PUBLIC API SẼ EXPORT

```dart
// ad_sdk.dart
export 'src/config/ad_config.dart';           // AdConfig, AdProvider, AppLovinConfig, AdMobConfig
export 'src/core/ad_manager.dart';            // AdManager
export 'src/core/ad_screen.dart';             // AdScreen, AdScreenState
export 'src/core/ad_route_observer.dart';     // adRouteObserver, AdScreenRouteLogger
export 'src/core/ad_safety_config.dart';      // AdSafetyConfig
export 'src/widget/banner_ad_widget.dart';    // BannerAdWidget
export 'src/widget/ad_loading_dialog.dart';   // AdLoadingDialog
```

**KHÔNG export (internal):**
- `safe_logger.dart`
- `ad_preferences.dart`
- `event_bus.dart`
- `shimmer_view.dart`

---

## 5. DEPENDENCIES CỦA PACKAGE

```yaml
# pubspec.yaml của package
name: ad_sdk
description: Dual-provider ad SDK for Flutter (AdMob + AppLovin MAX) with built-in safety throttle, VIP bypass, and RouteAware banner lifecycle.
version: 1.0.0
homepage: https://github.com/[username]/ad_sdk

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: '>=3.10.0'

dependencies:
  flutter:
    sdk: flutter
  google_mobile_ads: ^6.0.0
  applovin_max: ^4.6.3
  shared_preferences: ^2.5.0
  advertising_id: ^3.0.0
  connection_notifier: ^2.0.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
```

---

## 6. DEMO APP (example/)

Demo app sẽ simulate WiFiStressor flow:

| Screen | Ad type |
|---|---|
| `SplashScreen` | App Open Ad |
| `HomeScreen` | Banner + Inter on button tap |
| `DetailScreen` | Rewarded unlock |
| `HistoryScreen` | Banner |

Demo app phải dùng **test Ad Unit IDs** của Google/AppLovin — không hardcode production IDs.

---

## 7. PUB.DEV CHECKLIST

| Item | Status |
|---|---|
| `README.md` với badges + quickstart | ❌ Cần viết |
| `CHANGELOG.md` | ❌ Cần viết |
| `LICENSE` (MIT) | ❌ Cần tạo |
| `example/` app buildable | ❌ Cần tạo |
| `pubspec.yaml` đúng format | ❌ Cần tạo |
| Dart doc comments trên public API | ❌ Cần thêm |
| `flutter pub publish --dry-run` pass | ❌ Chưa test |
| Pub.dev score ≥ 70 (Likes, Pub Points, Popularity) | ❌ Target |
| API docs auto-generated | ❌ Cần `dart doc` |
| Platforms: Android ✅, iOS ✖️ chưa test | ⚠️ |

---

## 8. IMPLEMENTATION ROADMAP

### Phase 1 — Repo Setup (0.5 ngày)
- [ ] Tạo repo mới `dual_ad_manager/` (có thể dùng `flutter create --template=package .`)
- [ ] Copy file structure từ project hiện tại
- [ ] Cập nhật `pubspec.yaml` package

### Phase 2 — Core Refactor (1.5 ngày)
- [ ] Tạo `AdConfig` class thay thế `k.dart`
- [ ] Inject `AdConfig` vào `AdManager.initialize()`
- [ ] Bỏ `BaseStatefulState` dependency trong `AdScreenState`
- [ ] Make `AdSafetyConfig` configurable (không hardcode)
- [ ] Update tất cả `import` sang `src/` paths
- [ ] Thêm `dart doc` comments cho mọi public class/method

### Phase 3 — Example App (1 ngày)
- [ ] Tạo `example/` app: Splash → Home → Detail → History
- [ ] Dùng AppLovin test IDs
- [ ] Tạo `android/AndroidManifest.xml` đúng với lib

### Phase 4 — Docs + Publish prep (1 ngày)
- [ ] Viết `README.md` (installation, quickstart, API reference, screenshots)
- [ ] Viết `CHANGELOG.md`
- [ ] Thêm `LICENSE` (MIT)
- [ ] Chạy `flutter pub publish --dry-run`
- [ ] Fix mọi warning từ `dart analyze`
- [ ] Chạy `dart doc` để preview API docs

### Phase 5 — Publish
- [ ] `flutter pub publish`
- [ ] Verify trên pub.dev dashboard

---

## 9. RỦI RO & GIẢI PHÁP

| Rủi ro | Mức độ | Giải pháp |
|---|---|---|
| `AdConfig` inject quên gọi → crash | 🔴 Cao | Throw `StateError` rõ ràng nếu `initialize()` chưa gọi |
| iOS chưa test | 🟡 Vừa | AppLovin + AdMob đều support iOS, cần test simulator |
| pub.dev score thấp vì thiếu tests | 🟡 Vừa | Thêm unit tests cho `AdSafetyConfig` + `AdConfig` validation |
| `connection_notifier` version conflict | 🟢 Thấp | Dùng version constraint lỏng `^2.0.0` |
| `advertising_id` permission phức tạp | 🟡 Vừa | Document rõ trong README: cần `AD_ID` permission |

---

## 10. SO SÁNH VỚI CÁC PACKAGE TƯƠNG TỰ TRÊN PUB.DEV

| Package | Stars | Điểm khác biệt của chúng ta |
|---|---|---|
| `google_mobile_ads` | Official | Chỉ AdMob, không có safety layer |
| `applovin_max` | Official | Chỉ AppLovin, không có safety layer |
| `flutter_google_ad_manager` | ~50 | Không có AppLovin |
| **ad_sdk** | — | **Dual provider + AdSafety + RouteAware banner + VIP bypass** |

**USP (Unique Selling Point):**
1. 1 dòng switch giữa AdMob ↔ AppLovin: `AdProvider.admob` → `AdProvider.appLovin`
2. Built-in CTR fraud protection, throttle, daily/hourly caps
3. RouteAware banner — tự pause/resume đúng lifecycle
4. VIP device bypass — không show ad cho tester/owner
