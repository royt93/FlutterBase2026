# 📊 KẾ HOẠCH TÍCH HỢP QUẢNG CÁO — Flutter AdMob + AppLovin MAX

> Ngày tạo: 2026-03-21 | Version: 20260321
> Dual provider: **AdMob** (`google_mobile_ads`) + **AppLovin MAX** (`applovin_max`)
> Quy tắc code: Không `late`, không `!`, dùng nullable. Không `setState`, dùng `ValueNotifier`. Zero memory leak.

---

## 1. TỔNG QUAN KIẾN TRÚC

### 1.1 Dual Provider Flow

```
kIsEnableAdmob = true  → dùng google_mobile_ads (AdMob)
kIsEnableAdmob = false → dùng applovin_max (AppLovin MAX)
```

> Đổi provider: chỉ cần đổi 1 constant `kIsEnableAdmob` trong `k.dart`.
> Toàn bộ code UI, Screen không thay đổi.

### 1.2 Ad Units

| Loại | AdMob Debug (Google Test) | AdMob Release | AppLovin |
|------|--------------------------|---------------|---------|
| Banner | `ca-app-pub-3940256099942544/6300978111` | `ca-app-pub-3612191981543807/1996868091` | `YOUR_APPLOVIN_BANNER_ID` |
| Interstitial | `ca-app-pub-3940256099942544/1033173712` | `ca-app-pub-3612191981543807/3270405402` | `YOUR_APPLOVIN_INTERSTITIAL_ID` |
| App Open | `ca-app-pub-3940256099942544/9257395921` | `ca-app-pub-3612191981543807/9683786426` | `YOUR_APPLOVIN_APP_OPEN_ID` |
| Rewarded | `ca-app-pub-3940256099942544/5224354917` | `ca-app-pub-3612191981543807/YOUR_ID` | `YOUR_APPLOVIN_REWARDED_ID` |

### 1.3 Cấu trúc Files (tất cả trong `lib/mckimquyen/admob/`)

| File | Vai trò |
|------|---------|
| `k/k.dart` | Constants: Ad Unit IDs, `kIsEnableAdmob`, `kAppLovinSdkKey` |
| `ad_safety_config.dart` | ⭐ 12 biện pháp chống Invalid Traffic (port từ `AdSafetyConfig` Kotlin) |
| `ad_manager.dart` | ⭐ Core singleton: init/load/show mọi loại ad — dual provider |
| `ad_screen.dart` | Base class cho màn hình có ad (`ValueNotifier`, không `setState`) |
| `widget/banner_ad_widget.dart` | Widget banner tái sử dụng với shimmer loading |
| `event_bus.dart` | `SimpleEventBus` — signal từ AdManager đến SplashScreen |
| `logger.dart` | Logger wrapper (tắt ở release) |

---

## 2. DEPENDENCIES

### Step 1: `pubspec.yaml`

```yaml
dependencies:
  # AdMob (đã có)
  google_mobile_ads: ^6.0.0
  gma_mediation_applovin:   # AdMob mediation adapter (đã có)

  # AppLovin MAX Flutter SDK — THÊM MỚI
  applovin_max: ^4.6.3

  # Network check (đã có)
  connection_notifier: ^2.0.1
```

> **Lưu ý:** `gma_mediation_applovin` chỉ dùng khi AdMob làm primary + AppLovin làm mediation adapter.
> Khi `kIsEnableAdmob = false`, ta dùng `applovin_max` trực tiếp, không qua AdMob mediation.

### Step 2: `android/app/build.gradle`

Thêm `buildConfigField` để control provider từ build:

```groovy
android {
    buildFeatures {
        buildConfig true
    }
    buildTypes {
        debug {
            buildConfigField "Boolean", "IS_ENABLE_ADMOB", "false"
            buildConfigField "String", "APPLOVIN_SDK_KEY", "\"YOUR_APPLOVIN_SDK_KEY\""
            buildConfigField "String", "APPLOVIN_BANNER_ID", "\"YOUR_BANNER_ID\""
            buildConfigField "String", "APPLOVIN_INTERSTITIAL_ID", "\"YOUR_INTERSTITIAL_ID\""
            buildConfigField "String", "APPLOVIN_APP_OPEN_ID", "\"YOUR_APP_OPEN_ID\""
        }
        release {
            buildConfigField "Boolean", "IS_ENABLE_ADMOB", "false" // đổi true khi production AdMob
            // production IDs
        }
    }
}

dependencies {
    // AppLovin native SDK (cho mediation)
    implementation("com.google.ads.mediation:applovin:13.2.0.1") // đã có
    // lifecycle-process cho App Open Ad lifecycle
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
}
```

> ⚠️ **KHÔNG** thêm `applovin.sdk.key` vào AndroidManifest — SDK v13+ crash nếu thêm.
> SDK Key truyền qua `AppLovinMAX.initialize(sdkKey)` trong Dart.

### Step 3: `android/app/src/main/AndroidManifest.xml`

Đã có đầy đủ. Chỉ cần đảm bảo:
```xml
<!-- AdMob App ID (App ID, không phải Ad Unit ID) -->
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-3612191981543807~9731053733" />

<!-- Đã có sẵn -->
<uses-permission android:name="com.google.android.gms.permission.AD_ID" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

---

## 3. K.DART — CONSTANTS

**File:** `lib/mckimquyen/admob/k/k.dart`

```dart
// Provider switch — đổi 1 dòng để chuyển provider
const bool kIsEnableAdmob = false; // false = AppLovin MAX, true = AdMob

// AppLovin SDK Key
const String kAppLovinSdkKey = "YOUR_APPLOVIN_SDK_KEY";

// AppLovin Ad Unit IDs
const String kAppLovinBannerId = "YOUR_APPLOVIN_BANNER_ID";
const String kAppLovinInterstitialId = "YOUR_APPLOVIN_INTERSTITIAL_ID";
const String kAppLovinAppOpenId = "YOUR_APPLOVIN_APP_OPEN_ID";
const String kAppLovinRewardedId = "YOUR_APPLOVIN_REWARDED_ID";

// AdMob Ad Unit IDs (production)
const String kBannerAdUnitId = "ca-app-pub-3612191981543807/1996868091";
const String kInterstitialAdUnitId = "ca-app-pub-3612191981543807/3270405402";
const String kRewardedAdUnitId = "ca-app-pub-3612191981543807/YOUR_ID";
const String kAppOpenAdUnitId = "ca-app-pub-3612191981543807/9683786426";
```

---

## 4. AD_SAFETY_CONFIG.DART — CHỐNG INVALID TRAFFIC

**File:** `lib/mckimquyen/admob/ad_safety_config.dart`

Port logic từ `AdSafetyConfig` trong `AdManager.kt` sang Dart. Dùng `Preferences` (SharedPreferences).

### 4.1 Constants

```dart
const int kMaxFullscreenAdsPerSession = 6;
const int kMaxFullscreenAdsPerHour = 3;
const int kMaxFullscreenAdsPerDay = 5;       // persistent SharedPreferences
const int kMinTimeBetweenFullscreenMs = 60000; // 60s
const int kMinSessionDurationMs = 10000;       // 10s
const int kMinTimeAppOpenResumeMs = 5000;      // 5s
const int kMaxRapidResumesPerMinute = 3;
const double kSuspiciousCtrThreshold = 0.30;   // 30%
const int kMaxClicksPerMinute = 3;
const int kBaseSuspiciousPauseMs = 30 * 60 * 1000;   // 30 phút
const int kMaxSuspiciousPauseMs = 24 * 60 * 60 * 1000; // 24 giờ
```

### 4.2 Các methods cần implement

```dart
class AdSafetyConfig {
  // Kiểm tra trước khi show fullscreen ad
  // Returns (canShow: bool, reason: String)
  static (bool, String) canShowFullscreenAd();

  // Kiểm tra trước khi show App Open Ad khi resume
  static bool canShowAppOpenOnResume();

  // Ghi nhận sau khi show
  static void recordFullscreenAdShown();

  // Ghi nhận click
  static void recordAdClick();

  // Progressive cooldown khi phát hiện spam
  static Future<void> triggerSuspiciousPause();

  // Init với SharedPreferences
  static Future<void> init();
}
```

### 4.3 State (không dùng late, dùng nullable)

```dart
static int? _sessionStartTime;
static int _fullscreenAdsShownInSession = 0;
static int? _lastFullscreenAdTime;
static int? _suspiciousPauseUntil;
static int _suspiciousViolationCount = 0;
static final List<int> _clickTimestamps = [];
static final List<int> _hourlyAdTimestamps = [];
static final List<int> _resumeTimestamps = [];
static bool _isColdStart = true;
static int? _lastAppOpenResumeTime;
```

---

## 5. AD_MANAGER.DART — CORE SINGLETON

**File:** `lib/mckimquyen/admob/ad_manager.dart`

Singleton pattern (factory constructor), dual provider, zero `setState`, zero `late`.

### 5.1 Khởi tạo (Splash flow)

```
main() hoặc SplashScreen.initState()
  └→ AdManager().initialize()
       ├─ kIsEnableAdmob = true → MobileAds.instance.initialize()
       │    └→ _loadAppOpenAd() → EventBus.fire(true/false)
       └─ kIsEnableAdmob = false → AppLovinMAX.initialize(kAppLovinSdkKey)
            └→ AppLovinMAX.setAppOpenAdListener(...)
            └→ AppLovinMAX.loadAppOpenAd(kAppLovinAppOpenId)
            └→ EventBus.fire(true/false) từ listener
```

#### Hard cap 8 giây (giống Kotlin)

```dart
// SplashScreen nhận signal từ EventBus
// Đồng thời set Timer 8s hard cap
// Ai fire trước thì navigate (AtomicBoolean = bool + flag)
```

### 5.2 App Open Ad

#### AdMob:
```dart
// Load
await AppOpenAd.load(
  adUnitId: _appOpenAdUnitId(),
  request: const AdRequest(),
  adLoadCallback: AppOpenAdLoadCallback(...),
);

// Show
_appOpenAd?.show();
```

#### AppLovin MAX:
```dart
// Khởi tạo listener 1 lần
AppLovinMAX.setAppOpenAdListener(AppOpenAdListener(
  onAdLoadedCallback: (ad) { isMaxAppOpenReady = true; ... },
  onAdLoadFailedCallback: (adUnitId, error) { ... },
  onAdDisplayedCallback: (ad) { ... },
  onAdHiddenCallback: (ad) {
    // preload lại
    AppLovinMAX.loadAppOpenAd(kAppLovinAppOpenId);
  },
));

// Load
AppLovinMAX.loadAppOpenAd(kAppLovinAppOpenId);

// Show
final isReady = await AppLovinMAX.isAppOpenAdReady(kAppLovinAppOpenId);
if (isReady) AppLovinMAX.showAppOpenAd(kAppLovinAppOpenId);
```

#### Skip conditions (dùng AdSafetyConfig):
- Cold start (lần đầu tiên)  
- Background < 5s  
- Rapid resume > 3 lần/phút  
- `adReady = false`  
- SplashScreen đang active

### 5.3 Interstitial Ad

#### AdMob:
```dart
// Load
await InterstitialAd.load(
  adUnitId: _interstitialAdUnitId(),
  request: const AdRequest(),
  adLoadCallback: InterstitialAdLoadCallback(
    onAdLoaded: (ad) { _interstitialAd = ad; ... },
    onAdFailedToLoad: (error) { _startCooldown(); },
  ),
);

// Show
void showInterstitial(Function(bool) onDoneFlow) {
  if (!AdSafetyConfig.canShowFullscreenAd().$1) { onDoneFlow(false); return; }
  _interstitialAd?.fullScreenContentCallback = FullScreenContentCallback(
    onAdDismissedFullScreenContent: (ad) {
      ad.dispose();
      _interstitialAd = null;
      AdSafetyConfig.recordFullscreenAdShown();
      onDoneFlow(true);
      loadInterstitial(); // preload lại
    },
    onAdFailedToShowFullScreenContent: (ad, error) {
      ad.dispose();
      _interstitialAd = null;
      onDoneFlow(false);
    },
  );
  _interstitialAd?.show();
}
```

#### AppLovin MAX:
```dart
// Load
AppLovinMAX.setInterstitialListener(InterstitialListener(
  onAdLoadedCallback: (ad) { _isMaxInterstitialReady = true; ... },
  onAdLoadFailedCallback: (adUnitId, error) { _startCooldown(); },
  onAdDisplayedCallback: (ad) {
    AdSafetyConfig.recordFullscreenAdShown();
  },
  onAdHiddenCallback: (ad) {
    _isMaxInterstitialReady = false;
    _pendingInterstitialCallback?.call(true);
    _pendingInterstitialCallback = null;
    AppLovinMAX.loadInterstitial(kAppLovinInterstitialId); // preload lại
  },
  onAdDisplayFailedCallback: (ad, error) {
    _pendingInterstitialCallback?.call(false);
    _pendingInterstitialCallback = null;
  },
));
AppLovinMAX.loadInterstitial(kAppLovinInterstitialId);

// Show
void showInterstitial(Function(bool) onDoneFlow) {
  if (!AdSafetyConfig.canShowFullscreenAd().$1) { onDoneFlow(false); return; }
  _pendingInterstitialCallback = onDoneFlow;
  AppLovinMAX.showInterstitial(kAppLovinInterstitialId);
}
```

### 5.4 Banner Ad

#### Pattern chung (không dùng setState, dùng ValueNotifier):

```dart
// AdMobBannerNotifier trong AdScreen
final ValueNotifier<BannerAd?> bannerNotifier = ValueNotifier(null);
```

> ⚠️ AppLovin banner dùng `MaxAdView` widget — không có object như `BannerAd` của AdMob.
> Widget được render trực tiếp với `MaxAdView(adUnitId: ...)`.
> State quản lý bằng `ValueNotifier<bool> bannerLoadedNotifier`.

#### AdMob Banner:
```dart
// Load
final size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
    MediaQuery.of(context).size.width.truncate());
final ad = BannerAd(
  adUnitId: _bannerAdUnitId(),
  size: size ?? AdSize.banner,
  request: const AdRequest(),
  listener: BannerAdListener(
    onAdLoaded: (ad) { bannerNotifier.value = ad as BannerAd; },
    onAdFailedToLoad: (ad, error) { ad.dispose(); },
  ),
)..load();
```

#### AppLovin MAX Banner (Widget):
```dart
// Dùng trực tiếp MaxAdView widget (không cần load riêng)
// Kết hợp với shimmer ValueNotifier
final ValueNotifier<bool> maxBannerLoadedNotifier = ValueNotifier(false);

// Trong Widget tree:
MaxAdView(
  adUnitId: kAppLovinBannerId,
  adFormat: AdFormat.banner,
  listener: AdViewAdListener(
    onAdLoadedCallback: (ad) => maxBannerLoadedNotifier.value = true,
    onAdLoadFailedCallback: (adUnitId, error) => maxBannerLoadedNotifier.value = false,
  ),
)
```

### 5.5 Rewarded Ad

Tương tự Interstitial, nhưng có thêm callback `onUserEarnedReward`:

#### AdMob:
```dart
_rewardedAd?.show(onUserEarnedReward: (ad, reward) => onReward?.call());
```

#### AppLovin MAX:
```dart
AppLovinMAX.setRewardedAdListener(RewardedAdListener(
  onAdReceivedRewardCallback: (ad, reward) => _pendingRewardCallback?.call(),
  onAdHiddenCallback: (ad) => AppLovinMAX.loadRewardedAd(kAppLovinRewardedId),
));
```

### 5.6 Error Cooldown

```dart
static const int kErrorCooldownMs = 15 * 60 * 1000; // 15 phút
int? _lastInterstitialErrorTime;
int? _lastAppOpenErrorTime;

bool _isInCooldown(int? lastErrorTime) {
  if (lastErrorTime == null) return false;
  return DateTime.now().millisecondsSinceEpoch - lastErrorTime < kErrorCooldownMs;
}
```

### 5.7 VIP / Whitelist

```dart
// Nếu thiết bị là VIP → skip tất cả ad
bool _isVipDevice = false;

// Init từ SharedPreferences (danh sách GAID saved)
// Nếu _isVipDevice = true → load/show đều return sớm
```

### 5.8 State Summary (không `late`, không `!`)

```dart
class AdManager {
  static final AdManager _instance = AdManager._internal();
  factory AdManager() => _instance;
  AdManager._internal();

  // Shared
  bool _isVipDevice = false;
  bool _isSplashActive = true; // prevent App Open Ad trong splash

  // AdMob
  AppOpenAd? _admobAppOpenAd;
  InterstitialAd? _admobInterstitialAd;
  RewardedAd? _admobRewardedAd;
  DateTime? _appOpenAdLoadTime;
  bool _isAppOpenShowing = false;

  // AppLovin MAX
  bool _isMaxInterstitialReady = false;
  bool _isMaxAppOpenReady = false;
  bool _isMaxRewardedReady = false;
  Function(bool)? _pendingInterstitialCallback;
  Function()? _pendingRewardCallback;
  Function(bool)? _pendingAppOpenCallback;
}
```

---

## 6. BANNER_AD_WIDGET.DART — SHIMMER + PROVIDER AGNOSTIC

**File:** `lib/mckimquyen/admob/widget/banner_ad_widget.dart`

```
┌─────────────────────────────────┐
│ [AD] ← shimmer loading state    │  ← ValueNotifier<bool> isLoaded = false
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  ← shimmer placeholder
└─────────────────────────────────┘

┌─────────────────────────────────┐
│ [AD] ← LabelAd widget           │  ← ValueNotifier<bool> isLoaded = true
│ ┌─────────────────────────────┐ │
│ │ AdWidget(ad) / MaxAdView    │ │
│ └─────────────────────────────┘ │
└─────────────────────────────────┘
```

### Pattern (ValueNotifier, không setState):

```dart
class BannerAdWidget extends StatefulWidget { ... }

class _BannerAdWidgetState extends State<BannerAdWidget> {
  final ValueNotifier<bool> _isLoaded = ValueNotifier(false);
  BannerAd? _bannerAd; // null = chưa load hoặc fail

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  Future<void> _loadAd() async {
    if (kIsEnableAdmob) {
      // load BannerAd, khi loaded: _isLoaded.value = true
    } else {
      // MaxAdView tự load, listener set _isLoaded.value = true
    }
  }

  @override
  void dispose() {
    _isLoaded.dispose();
    _bannerAd?.dispose();
    _bannerAd = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _isLoaded,
      builder: (context, isLoaded, _) {
        if (!isLoaded) return _buildShimmer();
        return _buildRealAd();
      },
    );
  }
}
```

---

## 7. AD_SCREEN.DART — BASE CLASS (refactor)

**File:** `lib/mckimquyen/admob/ad_screen.dart`

Refactor để hỗ trợ dual provider. Không cần thay đổi nhiều vì `BannerAdWidget` đã tự handle provider.

```dart
abstract class AdScreenState<T extends AdScreen> extends BaseStatefulState<T> {
  // Banner: delegate cho BannerAdWidget — không cần ValueNotifier ở đây
  // Interstitial
  final ValueNotifier<bool> interstitialReadyNotifier = ValueNotifier(false);
  // Rewarded
  final ValueNotifier<bool> rewardedReadyNotifier = ValueNotifier(false);

  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    interstitialReadyNotifier.dispose();
    rewardedReadyNotifier.dispose();
    super.dispose();
  }

  Future<void> loadInterstitialAd() async {
    if (_isDisposed) return;
    await AdManager().loadInterstitial();
  }

  void showInterstitialAd(Function(bool) onDoneFlow) {
    if (_isDisposed) { onDoneFlow(false); return; }
    AdManager().showInterstitial(onDoneFlow);
  }

  void showRewardedAd({required VoidCallback onReward}) {
    if (_isDisposed) return;
    AdManager().showRewarded(onReward: onReward);
  }

  Widget buildBanner() => const BannerAdWidget();
}
```

---

## 8. MAIN.DART — INITIALIZATION FLOW

### 8.1 Splash flow với hard cap 8 giây

```dart
// SplashScreen
class _SplashScreenState extends State<SplashScreen> {
  final ValueNotifier<bool> _isAdReady = ValueNotifier(false);
  bool _hasNavigated = false; // thay cho AtomicBoolean
  Timer? _hardCapTimer;

  @override
  void initState() {
    super.initState();
    _initAd();
    _startHardCap();
  }

  void _startHardCap() {
    _hardCapTimer = Timer(const Duration(seconds: 8), () {
      _navigateToMain();
    });
  }

  Future<void> _initAd() async {
    AdManager().markSplashActive();
    await AdManager().initialize(
      onDone: (success) {
        if (success) AdManager().showAppOpenAdForSplash(() {
          _navigateToMain();
        });
        else _navigateToMain();
      },
    );
  }

  void _navigateToMain() {
    if (_hasNavigated) return;
    _hasNavigated = true;
    _hardCapTimer?.cancel();
    AdManager().markSplashInactive();
    // navigate to main
  }

  @override
  void dispose() {
    _hardCapTimer?.cancel();
    _isAdReady.dispose();
    super.dispose();
  }
}
```

### 8.2 `main()` — Chỉ init cơ bản

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // KHÔNG gọi AdManager().initialize() ở đây
  // Để SplashScreen xử lý (hard cap 8s)
  runApp(const MyApp());
}
```

---

## 9. APP OPEN AD ON RESUME — LIFECYCLE

AppLovin MAX Flutter không có `ProcessLifecycleOwner` như Kotlin.
Ta dùng `WidgetsBindingObserver` trong `MyApp`:

```dart
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  DateTime? _pauseTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pauseTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final pauseDuration = DateTime.now().difference(_pauseTime ?? DateTime.now());
      if (AdSafetyConfig.canShowAppOpenOnResume()) {
        AdManager().showAppOpenAdOnResume();
      }
      _pauseTime = null;
    }
  }
}
```

---

## 10. CONSTANTS REFERENCE

```dart
// Splash
const int kMaxTotalSplashMs = 8000;        // Hard cap tuyệt đối

// App Open Ad
const int kAppOpenAdTimeoutMs = 4 * 60 * 60 * 1000; // 4h — ad hết hạn
const int kErrorCooldownMs = 15 * 60 * 1000;          // 15 phút cooldown

// AdSafetyConfig
const int kMinTimeBetweenFullscreenMs = 60000;  // 60s giữa mọi fullscreen ad
const int kMinTimeAppOpenResumeMs = 5000;        // Min 5s ở background
const int kMaxFullscreenAdsPerSession = 6;
const int kMaxFullscreenAdsPerHour = 3;
const int kMaxFullscreenAdsPerDay = 5;           // Persistent SharedPreferences
const int kMaxRapidResumesPerMinute = 3;
const int kMinSessionDurationMs = 10000;         // 10s đầu session skip
const double kSuspiciousCtrThreshold = 0.30;     // 30% cần ≥ 5 impressions
const int kMaxClicksPerMinute = 3;
const int kBaseSuspiciousPauseMs = 30 * 60 * 1000;   // 30 phút
const int kMaxSuspiciousPauseMs = 24 * 60 * 60 * 1000; // 24 giờ
```

---

## 11. AN TOÀN CODE

| Yêu cầu | Cách implement |
|---------|----------------|
| Không `late` | Dùng nullable (`BannerAd? _bannerAd`) |
| Không `!` force unwrap | Dùng `?.`, `??`, `if (x != null)` |
| Không `setState` | Dùng `ValueNotifier<T>` + `ValueListenableBuilder` |
| Không memory leak | `dispose()` tất cả `ValueNotifier`, `BannerAd`, `Timer`, `WidgetsBindingObserver` |
| Thread safety | Dart single-threaded, nhưng dùng `bool _hasNavigated` flag cho splash |
| Null callback | Clear callback sau khi invoke: `_pendingCallback?.call(); _pendingCallback = null;` |
| Observer leak | `WidgetsBinding.instance.removeObserver(this)` trong `dispose()` |
| Ad disposed | Check `_isDisposed` trước mọi operation trong async callback |

---

## 12. CHECKLIST TÍCH HỢP

| # | Task | File | Status |
|---|------|------|--------|
| 1 | Thêm `applovin_max: ^4.6.3` vào pubspec.yaml | `pubspec.yaml` | ☐ |
| 2 | Thêm `buildConfigField` cho ad IDs + IS_ENABLE_ADMOB | `android/app/build.gradle` | ☐ |
| 3 | Thêm `lifecycle-process` dependency | `android/app/build.gradle` | ☐ |
| 4 | Update `k/k.dart` — thêm AppLovin IDs + `kIsEnableAdmob` + `kAppLovinSdkKey` | `admob/k/k.dart` | ☐ |
| 5 | Tạo `ad_safety_config.dart` — port 12 biện pháp từ Kotlin | `admob/ad_safety_config.dart` | ☐ |
| 6 | Refactor `ad_manager.dart` → dual provider singleton | `admob/ad_manager.dart` | ☐ |
| 7 | Tạo `widget/banner_ad_widget.dart` — shimmer + dual provider | `admob/widget/banner_ad_widget.dart` | ☐ |
| 8 | Refactor `ad_screen.dart` → delegate to AdManager | `admob/ad_screen.dart` | ☐ |
| 9 | Update `SplashScreen` — hard cap 8s + App Open Ad | `widget/splash/splash_screen.dart` | ☐ |
| 10 | Update `main.dart` — add `WidgetsBindingObserver` cho App Open lifecycle | `main.dart` | ☐ |
| 11 | Sửa `screen_a.dart`, `screen_b.dart`, `screen_c.dart` — dùng API mới | `admob/screen_*.dart` | ☐ |
| 12 | Test debug với logcat `roy93~AdManager` | - | ☐ |
| 13 | Điền AppLovin Ad Unit IDs thật vào `k.dart` | `admob/k/k.dart` | ☐ |

---

## 13. DUAL PROVIDER REFERENCE

### AdMob ↔ AppLovin MAX Flutter API Mapping

| Feature | AdMob (google_mobile_ads) | AppLovin MAX (applovin_max) |
|---------|--------------------------|---------------------------|
| Init | `MobileAds.instance.initialize()` | `AppLovinMAX.initialize(sdkKey)` |
| Banner | `BannerAd` object | `MaxAdView` widget |
| Banner load | `BannerAd(...).load()` | `MaxAdView` tự load khi mount |
| Interstitial load | `InterstitialAd.load(...)` | `AppLovinMAX.loadInterstitial(adUnitId)` |
| Interstitial ready | check `_interstitialAd != null` | `AppLovinMAX.isInterstitialReady(adUnitId)` |
| Interstitial show | `_interstitialAd?.show()` | `AppLovinMAX.showInterstitial(adUnitId)` |
| App Open load | `AppOpenAd.load(...)` | `AppLovinMAX.loadAppOpenAd(adUnitId)` |
| App Open ready | check `_appOpenAd != null` | `AppLovinMAX.isAppOpenAdReady(adUnitId)` |
| App Open show | `_appOpenAd?.show()` | `AppLovinMAX.showAppOpenAd(adUnitId)` |
| Rewarded load | `RewardedAd.load(...)` | `AppLovinMAX.loadRewardedAd(adUnitId)` |
| Rewarded show | `_rewardedAd?.show(onUserEarnedReward:)` | `AppLovinMAX.showRewardedAd(adUnitId)` |
| Test mode | `RequestConfiguration.testDeviceIds` | `AppLovinMAX.setTestDeviceAdvertisingIds([gaid])` |

### Chuyển đổi provider

```dart
// k/k.dart — đổi 1 dòng
const bool kIsEnableAdmob = true;   // → AdMob
const bool kIsEnableAdmob = false;  // → AppLovin MAX
```

---

## 14. KNOWN ISSUES & NOTES

| Issue | Giải pháp |
|-------|-----------|
| `MaxAdView` không có lifecycle `resume/pause` như `AdView` | Không cần — AppLovin tự handle khi widget visible/invisible |
| App Open Ad AdMob hết hạn sau 4h | Check `DateTime.now().difference(_appOpenAdLoadTime).inHours >= 4` trước khi show |
| AppLovin App Open Ad không có load time check | AppLovin SDK tự cache và quản lý validity |
| `WidgetsBindingObserver` trong MyApp gây double show | Dùng flag `_isSplashActive` trong AdManager để block khi splash đang hiển thị |
| Dart không có `synchronized {}` | Dart single-threaded, không cần. Dùng `bool` flag + async/await |
| `onAdLoadFailedCallback` AppLovin không auto retry | Phải gọi `AppLovinMAX.loadInterstitial()` lại thủ công trong callback |
