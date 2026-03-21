# 📊 TÍCH HỢP QUẢNG CÁO (AdMob + AppLovin MAX) — FLUTTER

> Version: 20260321-final | Provider: AdMob & AppLovin MAX (dual)
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
| **`wasActuallyShown` log** phân biệt blocked vs dismissed thật | ✅ | — | — | — |
| **AppLovin Stack deadlock fix** (MaxAdView luôn mounted) | — | — | — | ✅ |

---

## 3. INTEGRATION GUIDE — STEP BY STEP (Junior Dev)

### ⏱ Thời gian: ~40 phút

---

### STEP 1: Thêm Dependencies — `pubspec.yaml`

```yaml
dependencies:
  # Ad SDKs
  google_mobile_ads: ^6.0.0
  applovin_max: ^4.6.3

  # Utilities
  shared_preferences: ^2.5.3
  connection_notifier: ^2.0.1
```

Chạy: `flutter pub get`

---

### STEP 2: Android Config — `android/app/build.gradle`

```groovy
android {
    buildFeatures { buildConfig true }
}
dependencies {
    implementation("com.google.ads.mediation:applovin:13.2.0.1")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
}
```

---

### STEP 3: AndroidManifest.xml

> ⚠️ KHÔNG thêm `applovin.sdk.key` vào manifest (SDK v13+ crash nếu thêm).
> SDK Key truyền qua `AppLovinMAX.initialize(sdkKey)` trong Dart.

```xml
<manifest>
    <uses-permission android:name="com.google.android.gms.permission.AD_ID" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

    <application>
        <!-- AdMob App ID của bạn -->
        <meta-data
            android:name="com.google.android.gms.ads.APPLICATION_ID"
            android:value="ca-app-pub-XXXXXXXXXXXXXXXX~XXXXXXXXXX" />
    </application>
</manifest>
```

---

### STEP 4: Copy Toàn Bộ Thư Mục Ad

Copy folder `lib/mckimquyen/ad/` vào project mới của bạn.

---

### STEP 5: Cấu hình Ad IDs — `k/k.dart`

```dart
import 'package:flutter/foundation.dart';

// ═══════ PROVIDER SWITCH — CHỈ CẦN ĐỔI 1 DÒNG NÀY ═══════
const bool kIsEnableAdmob = false; // true = AdMob, false = AppLovin

// ═══════ APPLOVIN CONFIG ═══════
const String kAppLovinSdkKey         = "YOUR_APPLOVIN_SDK_KEY";
const String kAppLovinBannerId        = "YOUR_BANNER_UNIT_ID";
const String kAppLovinInterstitialId  = "YOUR_INTER_UNIT_ID";
const String kAppLovinAppOpenId       = "YOUR_APP_OPEN_UNIT_ID";
const String kAppLovinRewardedId      = "YOUR_REWARDED_UNIT_ID";

// ═══════ ADMOB CONFIG ═══════
const String kAdmobBannerAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/6300978111"     // test
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";     // production

const String kAdmobInterstitialAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/1033173712"
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";

const String kAdmobAppOpenAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/9257395921"
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";

const String kAdmobRewardedAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/5224354917"
    : "ca-app-pub-XXXXXXXXXXXXXXXX/XXXXXXXXXX";

// ═══════ TEST DEVICES (AdMob dùng GAID hash MD5) ═══════
const List<String> kTestDeviceIds = [
  "YOUR_TEST_DEVICE_HASH_1",
  "YOUR_TEST_DEVICE_HASH_2",
];

// ═══════ VIP MEMBER GAID LIST ═══════
// Các GAID này sẽ KHÔNG thấy quảng cáo bao giờ
const List<String> kVipDeviceGaids = [
  "your-gaid-uuid-1",
  "your-gaid-uuid-2",
];
```

---

### STEP 6: Khởi động AdManager — `main.dart`

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: SplashScreen(),
    );
  }
}
```

> ✅ `AdManager` tự gắn `WidgetsBindingObserver` trong constructor — **KHÔNG cần** gắn thêm ở `main.dart`.

---

### STEP 7: Splash Screen — Nơi Init Ad

```dart
class SplashScreen extends StatefulWidget { ... }

class _SplashScreenState extends State<SplashScreen> {
  bool _hasNavigated = false;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _startSplash();
  }

  void _startSplash() {
    // 1) Đánh dấu Splash đang active (chặn showAppOpenAdOnResume)
    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // 2) Hard-cap timer 8s — nếu SDK chậm vẫn vào app được
    Future.delayed(const Duration(seconds: 8), () {
      _navigateToMainSafely(initAdSuccess: false);
    });

    // 3) Subscribe EventBus để biết Ad init xong
    _subscription = AdManager().eventBusStream.listen((success) {
      if (success) {
        _loadAndShowAppOpenAd();
      } else {
        _navigateToMainSafely(initAdSuccess: false);
      }
    });

    // 4) Bắt đầu init AdManager
    AdManager().initialize(
      onComplete: (success, _) {
        // Đã phát qua EventBus, không cần làm thêm ở đây
      },
    );
  }

  void _loadAndShowAppOpenAd() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (!mounted || _hasNavigated) return;
      if (loaded) {
        AdManager().showAppOpenAd(
          bypassSafety: true, // Bỏ qua AdSafety cho splash
          onAdDismiss: (_) => _navigateToMainSafely(initAdSuccess: true),
        );
      } else {
        _navigateToMainSafely(initAdSuccess: false);
      }
    });
  }

  void _navigateToMainSafely({required bool initAdSuccess}) {
    if (_hasNavigated) return;
    _hasNavigated = true;
    _subscription?.cancel();
    AdManager().markSplashInactive(); // Cho phép showAppOpenAdOnResume hoạt động
    // Navigate to main screen
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MainScreen()));
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
```

---

### STEP 8: Screen Có Ads — Kế thừa `AdScreenState`

```dart
class MyScreen extends StatefulWidget { ... }

class _MyScreenState extends AdScreenState<MyScreen> {
  @override
  void initState() {
    super.initState();
    // Inter và Rewarded được preload sẵn bởi AdManager — không cần gọi load ở đây
  }

  void _onGoToNextScreen() {
    // Gọi inter trước khi navigate
    showInterstitialAd(onDoneFlow: (shown) {
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => NextScreen()));
    });
  }

  void _onWatchRewardedAd() {
    AdManager().showRewardedAd(onEarnedReward: (earned) {
      if (earned) {
        // Đã xem đủ → phát thưởng cho user
        setState(() { coins += 10; });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // BannerAdWidget tự quản lý lifecycle — đặt ở cuối màn hình
          const BannerAdWidget(),
        ],
      ),
    );
  }
}
```

---

### STEP 9: Sử dụng BannerAdWidget

```dart
// Đặt ở bất kỳ đâu trong widget tree — tự quản lý toàn bộ lifecycle
const BannerAdWidget()
```

**Không cần:**
- Gọi `load()` thủ công
- Gọi `dispose()` thủ công
- Xử lý callback loading

**BannerAdWidget tự động:**
- Kiểm tra VIP → ẩn nếu VIP
- Kiểm tra mạng → ẩn nếu offline
- Kiểm tra navigation cooldown 5s → ẩn nếu navigate quá nhanh
- Hiện shimmer trong khi load
- Chuyển sang ad thật khi load xong
- Dispose sạch khi widget bị remove

---

### STEP 10: AdSafety Tuning (Tuỳ chỉnh giới hạn)

Trong `ad_safety_config.dart`, bạn có thể đổi các constant:

```dart
// Thời gian tối thiểu giữa 2 fullscreen ad (ms)
static const int _minTimeBetweenFullscreenAds = 60000;   // 60s — khuyến nghị giữ nguyên

// Giới hạn số lần show
static const int _maxFullscreenAdsPerSession = 6;  // 6 lần/session
static const int _maxFullscreenAdsPerHour    = 3;  // 3 lần/giờ
static const int _maxFullscreenAdsPerDay     = 5;  // 5 lần/ngày

// Resume protection
static const int _minTimeAppOpenResume       = 5000;  // App phải background ≥ 5s

// Anti-fraud thresholds
static const double _suspiciousCtrThreshold  = 0.30;  // CTR > 30% → suspend
static const int    _maxClicksPerMinute      = 3;     // > 3 clicks/min → suspend
static const int    _maxRapidResumesPerMinute = 3;    // > 3 resume/min → skip
```

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
  → adReady=true, isShowing=false → SHOWING NOW
  → showAppOpenAd(bypassSafety: false)
  → AdSafety.canShowFullscreenAd() = true → show
  → User đóng → "ProcessLifecycle ✅ Ad dismissed by user" → preload next
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

### 5.2 AppLovin MaxAdView — Stack Fix

```
❌ Sai (deadlock): isLoaded=false → không render MaxAdView → MaxAdView không mount → callback không fire
✅ Đúng (Stack): MaxAdView luôn được mount → callback fire → isLoaded=true → shimmer ẩn
```

```dart
// AppLovin path trong build():
Stack(
  children: [
    _buildAdWidget(),              // MaxAdView LUÔN mounted
    if (!isLoaded)
      Positioned.fill(child: ShimmerView(...)),  // Shimmer overlay
  ],
)
```

### 5.3 Click Tracking

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

### 9.1 Log tốt (cần thấy)

```
✅ Ad Loaded successfully              ← Ad tải thành công
✅ Ad Shown full screen               ← Ad hiện lên
✅ Ad Dismissed by user               ← Ad bị tắt bởi user (THẬT)
📊 Ad SHOWN | session=X/6 | hourly=X/3 | daily=X/5  ← AdSafety counts
canLoadBanner ✅ load allowed, timer reset            ← Banner được load
```

### 9.2 Log Warning (quan sát)

```
⏭️ already loading, skip request      ← Mutex đang lock (tốt)
⏭️ ad already in memory, no need to reload  ← Cache hit (rất tốt)
⏭️ ad still valid (< 4h), no need to reload ← 4h cache hit (tốt)
⏭️ ad already ready, no need to reload      ← AppLovin guard (tốt)
🔄 Ad blocked/skipped before show           ← Safety chặn, KHÔNG phải dismissed
canLoadBanner ⏭️ cooldown active            ← Navigation quá nhanh
```

### 9.3 Log cần chú ý

```
🛡️ Throttle: wait Xs          ← Đang trong cooling down — bình thường
🛡️ Hourly cap: 3/3            ← Đã đạt giới hạn giờ — bình thường
🛡️ Skipping App Open on cold start  ← Lần resume đầu tiên — bình thường
🛡️ Resume too fast (Xms)      ← User vào/ra quá nhanh — bình thường
⚠️ SUSPICIOUS                 ← CTR hoặc click spam — cần kiểm tra
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

| Ngày | Thay đổi |
|------|----------|
| 20260321-v1 | Port từ Kotlin AdManager.kt — baseline |
| 20260321-v2 | Thêm WidgetsBindingObserver vào AdManager |
| 20260321-v3 | Fix banner adaptive full-width (Anchored Adaptive) |
| 20260321-v4 | Thêm Rewarded Ad flow + preload toàn bộ ad khi init |
| 20260321-v5 | Thêm mutex lock `_isAppOpenLoading`, `_isInterLoading` |
| 20260321-v6 | Thêm 4h cache validity cho App Open |
| 20260321-v7 | Fix AppLovin Banner deadlock bằng Stack widget |
| 20260321-v8 | Thêm `_isInterstitialShowing`, `_isRewardedShowing` guard |
| 20260321-v9 | Thêm in-memory guard cho Interstitial và Rewarded |
| 20260321-v10 | Fix false `dismissed` log — `wasActuallyShown` branching |
| 20260321-v11 | Thêm `_isMaxInterReady` guard cho AppLovin Interstitial |
| 20260321-v12 | Thêm Banner navigation cooldown 5s |
| **20260321-final** | **Tài liệu hoàn chỉnh — Production Ready** |

