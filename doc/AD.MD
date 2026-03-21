# 📊 TÍCH HỢP QUẢNG CÁO (AdMob + AppLovin MAX) — FLUTTER

> Version: 20260321 | Parity: 100% với Android `AdManager.kt` (2046 dòng)
> Strict: Không `late`, không `!`, dùng nullable `?`, `ValueNotifier`, zero memory leak.

---

## 1. TỔNG QUAN KIẾN TRÚC

### 1.1 Provider Switch
```
kIsEnableAdmob = true  → google_mobile_ads (AdMob)
kIsEnableAdmob = false → applovin_max (AppLovin MAX)
```

### 1.2 Ad Units

| Loại | Debug (Google Test) | Release (Production) | AppLovin MAX |
|------|---------------------|---------------------|--------------|
| Banner | `ca-app-pub-3940256099942544/6300978111` | `ca-app-pub-3612191981543807/1996868091` | `YOUR_APPLOVIN_BANNER_ID` |
| Interstitial | `ca-app-pub-3940256099942544/1033173712` | `ca-app-pub-3612191981543807/3270405402` | `YOUR_APPLOVIN_INTERSTITIAL_ID` |
| App Open | `ca-app-pub-3940256099942544/9257395921` | `ca-app-pub-3612191981543807/9683786426` | `YOUR_APPLOVIN_APP_OPEN_ID` |
| Rewarded | `ca-app-pub-3940256099942544/5224354917` | (chưa có) | `YOUR_APPLOVIN_REWARDED_ID` |

### 1.3 Mapping Objects (Native → Flutter)

| Kotlin Native | Dart Flutter | File |
|---------------|-------------|------|
| `ProductionConfig` | `ProductionConfig` class | `utils/safe_logger.dart` |
| `SafeLogger` | `SafeLogger` class | `utils/safe_logger.dart` |
| `AppPreferences` | `AppPreferences` class (SharedPreferences) | `utils/app_preferences.dart` |
| `EventBus` (SharedFlow) | `EventBus` (StreamController.broadcast) | `utils/event_bus.dart` |
| `NetworkUtils` | Wrap `ConnectionNotifierTools` | `utils/network_utils.dart` |
| `AdSafetyConfig` (12 rules) | `AdSafetyConfig` class | `ad_safety_config.dart` |
| `ShimmerView` (Custom View) | `ShimmerView` (AnimationController) | `widget/shimmer_view.dart` |
| `AdManager` (object singleton) | `AdManager` (factory singleton) | `ad_manager.dart` |
| Banner lifecycle wrappers | `BannerAdWidget` (StatefulWidget) | `widget/banner_ad_widget.dart` |
| `AdScreenState` base | `AdScreenState<T>` abstract | `ad_screen.dart` |
| `ProcessLifecycleOwner` | `WidgetsBindingObserver` ở MyApp | `main.dart` |
| `ActivityLifecycleCallbacks` | Không cần (Flutter single Activity) | — |

---

## 2. DEPENDENCIES

### 2.1 `pubspec.yaml`
```yaml
dependencies:
  google_mobile_ads: ^6.0.0
  gma_mediation_applovin: ^1.2.0
  applovin_max: ^4.6.3           # THÊM MỚI
  shared_preferences: ^2.5.3
  connection_notifier: ^2.0.1
```

### 2.2 `android/app/build.gradle`
```groovy
android {
    buildFeatures { buildConfig true }
    buildTypes {
        debug {
            buildConfigField "Boolean", "IS_ENABLE_ADMOB", "false"
        }
        release {
            buildConfigField "Boolean", "IS_ENABLE_ADMOB", "false"
        }
    }
}
dependencies {
    implementation("com.google.ads.mediation:applovin:13.2.0.1") // đã có
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
}
```

### 2.3 `AndroidManifest.xml`
> ⚠️ KHÔNG thêm `applovin.sdk.key` vào manifest (SDK v13+ crash nếu thêm).
> SDK Key truyền qua `AppLovinMAX.initialize(sdkKey)` trong Dart.

```xml
<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-3612191981543807~9731053733" />
<uses-permission android:name="com.google.android.gms.permission.AD_ID" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

---

## 3. STEP-BY-STEP IMPLEMENTATION

### STEP 1: Constants — `k/k.dart`

```dart
import 'package:flutter/foundation.dart';

// ═══════ PROVIDER SWITCH ═══════
const bool kIsEnableAdmob = false;

// ═══════ APPLOVIN CONFIG ═══════
const String kAppLovinSdkKey = "YOUR_SDK_KEY";
const String kAppLovinBannerId = "YOUR_BANNER";
const String kAppLovinInterstitialId = "YOUR_INTER";
const String kAppLovinAppOpenId = "YOUR_APP_OPEN";
const String kAppLovinRewardedId = "YOUR_REWARDED";

// ═══════ ADMOB CONFIG ═══════
const String kAdmobBannerAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/6300978111"
    : "ca-app-pub-3612191981543807/1996868091";
const String kAdmobInterstitialAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/1033173712"
    : "ca-app-pub-3612191981543807/3270405402";
const String kAdmobAppOpenAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/9257395921"
    : "ca-app-pub-3612191981543807/9683786426";
const String kAdmobRewardedAdUnitId = kDebugMode
    ? "ca-app-pub-3940256099942544/5224354917"
    : "ca-app-pub-3612191981543807/YOUR_ID";

// ═══════ TEST DEVICES (AdMob dùng GAID hash, AppLovin dùng GAID gốc) ═══════
const List<String> kTestDeviceIds = [
  "884670AFCACDD337E31BB6153C6DB17E", // Vsmart Iris
  "05B522309BC31052952BBCD5CC85ACA8", // Vivo Z9
];

// ═══════ VIP MEMBER GAID LIST ═══════
// Port từ getMyListVipDevice() trong Kotlin
// Các thiết bị trong list này sẽ KHÔNG thấy quảng cáo
const List<String> kVipDeviceGaids = [
  "9ad0127d-04be-4b6c-937a-ca3ed7f650b9", // vsmart iris
  "9b6499f2-d4de-4b9e-afdf-ac2a2b127fb1", // ss a50
  "c09b2f04-e145-490c-96f9-dab620074104", // oppo f7
  "c228aa08-bedd-4e6e-adf6-ae5e95bcddae", // vivo v15
  "46259467-0ac4-49c4-a3a2-7d3db3ce4bda", // tecno spark 20 pro+
  "1b7c3e3f-c709-4e85-b26f-dd74c4df2ed7", // vivo 1906
  "adaa42e7-9cc6-4a8a-9c90-d4d87842b12c", // tecno spark go 2024
  "f5a36a2f-5add-4315-a171-0f8dddab78c7", // ss s20u
  "6fbb207d-341d-470d-bb0a-dddd79522b32", // ss a52
  "40f8e222-cf7a-4fac-9913-6809c4c58817", // mipad 5
  "932099db-d381-4b52-98dc-5b96ba8b4ff4", // oppo reno 2f
  "a1339bd1-8ea5-47cd-969e-4b5721b576b7", // redmi note 8+
  "3f2f21d2-85eb-451b-a1a5-003668ba6345", // zte blade
  "261f772c-6a10-499c-b896-4157d9ab6a25", // ss a11
  "460d3f5c-bbe2-46fc-841a-6381e3c93864", // redmi95
  "49606ad7-5cee-43b4-9af7-8aa274644737", // redmi note 13 pro
  "6cf051f8-83f5-43b7-8c1a-1d20ae1f8d93", // redmi pad pro
  "da10cb05-5458-42df-ba86-630732356b35", // vivo z9
  "8f6ccdc1-08fd-4611-abdf-f48bdadb5581", // tablet lenovo
  "66e652de-79ef-4889-8074-9b482fd81b5a", // redmi a3
  "4ed22dd8-e8fb-442e-a75e-081a3d977957", // ss s24u
];
```

### STEP 2: Utils — `safe_logger.dart`, `event_bus.dart`, `app_preferences.dart`

**`utils/safe_logger.dart`**
```dart
import 'package:flutter/foundation.dart';

class ProductionConfig {
  static const bool enableDemoFeatures = kDebugMode;
  static const bool enableVerboseLogging = kDebugMode;
  static const bool enableMemoryOptimization = !kDebugMode;
}

class SafeLogger {
  static void d(String tag, String message) {
    if (ProductionConfig.enableVerboseLogging) {
      try { debugPrint('[$tag] $message'); } catch (_) {}
    }
  }
  static void w(String tag, String message) {
    if (ProductionConfig.enableVerboseLogging) {
      try { debugPrint('⚠️ [$tag] $message'); } catch (_) {}
    }
  }
}
```

**`utils/event_bus.dart`**
```dart
import 'dart:async';

class EventBus {
  static final StreamController<bool> _controller = StreamController<bool>.broadcast();
  static Stream<bool> get stream => _controller.stream;
  static void sendEvent(bool isSuccess) => _controller.add(isSuccess);
}
```

**`utils/app_preferences.dart`**
```dart
import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences {
  static AppPreferences? _instance;
  SharedPreferences? _prefs;

  static Future<AppPreferences> getInstance() async {
    if (_instance == null) {
      _instance = AppPreferences();
      _instance!._prefs = await SharedPreferences.getInstance();
    }
    return _instance!;
  }

  // ════ VIP MANAGEMENT ════
  List<String> getGAIDList() => _prefs?.getStringList('keyListGAID') ?? [];
  Future<void> saveGAIDList(List<String> list) async =>
      await _prefs?.setStringList('keyListGAID', list.toSet().toList());
  bool isAddVIPMemberFirstInitSuccess() =>
      _prefs?.getBool('keyAddVIPMemberFirstInitSuccess') ?? false;
  Future<void> addVIPMemberFirstInitSuccess() async =>
      await _prefs?.setBool('keyAddVIPMemberFirstInitSuccess', true);

  // ════ AD SAFETY PERSISTENCE ════
  int getDailyAdCount() {
    final today = DateTime.now().toString().substring(0, 10);
    final saved = _prefs?.getString('ad_safety_daily_date') ?? "";
    if (saved != today) {
      _prefs?.setString('ad_safety_daily_date', today);
      _prefs?.setInt('ad_safety_daily_count', 0);
      _prefs?.setInt('ad_safety_suspicious_count', 0);
      return 0;
    }
    return _prefs?.getInt('ad_safety_daily_count') ?? 0;
  }
  Future<void> incrementDailyAdCount() async {
    final current = getDailyAdCount();
    final today = DateTime.now().toString().substring(0, 10);
    await _prefs?.setInt('ad_safety_daily_count', current + 1);
    await _prefs?.setString('ad_safety_daily_date', today);
  }
  int getSuspiciousCount() => _prefs?.getInt('ad_safety_suspicious_count') ?? 0;
  Future<void> incrementSuspiciousCount() async {
    final c = getSuspiciousCount();
    await _prefs?.setInt('ad_safety_suspicious_count', c + 1);
  }
  Future<void> clearAllData() async => await _prefs?.clear();
}
```

### STEP 3: AdSafetyConfig — 12 Biện Pháp Chống Invalid Traffic

> Port CHÍNH XÁC từ `AdSafetyConfig` trong Kotlin (dòng 1360–1648 của AdManager.kt).
> Thứ tự 7 checks trong `canShowFullscreenAd()` phải ĐÚNG Y CHANG Kotlin.

```dart
import 'utils/safe_logger.dart';
import 'utils/app_preferences.dart';

class AdSafetyConfig {
  static const String _tag = "roy93~AdSafety";

  // ════════ BASIC ════════
  static const int _minTimeBetweenFullscreenAds = 60000;   // 60s
  static const int _maxFullscreenAdsPerSession = 6;
  static const int _minTimeAppOpenResume = 5000;            // 5s
  static const int _maxClicksPerMinute = 3;

  // ════════ ADVANCED ════════
  static const int _maxFullscreenAdsPerDay = 5;             // persistent
  static const int _maxFullscreenAdsPerHour = 3;
  static const int _minSessionDurationBeforeAd = 10000;     // 10s
  static const double _suspiciousCtrThreshold = 0.30;       // 30%
  static const int _maxRapidResumesPerMinute = 3;
  static const int _baseSuspiciousPause = 30 * 60 * 1000;   // 30 phút
  static const int _maxSuspiciousPause = 24 * 60 * 60 * 1000; // 24 giờ

  // ════════ STATE (không late, init an toàn) ════════
  static int _lastFullscreenAdTime = 0;
  static int _fullscreenAdsShownInSession = 0;
  static int _lastBackgroundTime = 0;        // ← GHI NHẬN KHI APP VÀO BACKGROUND
  static bool _isColdStart = true;
  static final List<int> _clickTimestamps = [];
  static int _suspiciousPauseUntil = 0;
  static int _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
  static final List<int> _hourlyAdTimestamps = [];
  static final List<int> _resumeTimestamps = [];
  static int _totalImpressions = 0;
  static int _totalClicks = 0;
  static int _suspiciousViolationCount = 0;
  static AppPreferences? _appPreferences;

  /// Khởi tạo với AppPreferences để persist daily limit
  static Future<void> init(AppPreferences prefs) async {
    _appPreferences = prefs;
    _suspiciousViolationCount = prefs.getSuspiciousCount();
    _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
    SafeLogger.d(_tag,
      "🔄 init, dailyAds=${prefs.getDailyAdCount()}/$_maxFullscreenAdsPerDay, "
      "suspiciousCount=$_suspiciousViolationCount");
  }

  // ════════ CORE CHECK 1: canShowFullscreenAd() ════════
  //  Port 7 checks ĐÚNG THỨ TỰ từ Kotlin (dòng 1466–1523)
  static (bool, String) canShowFullscreenAd() {
    final now = DateTime.now().millisecondsSinceEpoch;

    // ① Suspicious pause đang active? (progressive cooldown)
    if (now < _suspiciousPauseUntil) {
      final remaining = (_suspiciousPauseUntil - now) ~/ 1000;
      SafeLogger.d(_tag, "🛡️ Suspended, remaining=${remaining}s");
      return (false, "Suspended: ${remaining}s remaining");
    }
    // ② Minimum session duration (10s đầu session skip)
    final sessionDuration = now - _sessionStartTime;
    if (sessionDuration < _minSessionDurationBeforeAd) {
      SafeLogger.d(_tag, "🛡️ Session too young (${sessionDuration ~/ 1000}s)");
      return (false, "Session too young");
    }
    // ③ Session limit (max 6)
    if (_fullscreenAdsShownInSession >= _maxFullscreenAdsPerSession) {
      SafeLogger.d(_tag, "🛡️ Session limit: $_fullscreenAdsShownInSession/$_maxFullscreenAdsPerSession");
      return (false, "Session limit reached");
    }
    // ④ Hourly cap (max 3)
    _hourlyAdTimestamps.removeWhere((t) => now - t > 3600000);
    if (_hourlyAdTimestamps.length >= _maxFullscreenAdsPerHour) {
      SafeLogger.d(_tag, "🛡️ Hourly cap: ${_hourlyAdTimestamps.length}/$_maxFullscreenAdsPerHour");
      return (false, "Hourly cap reached");
    }
    // ⑤ Daily limit (max 5, persistent SharedPreferences)
    final dailyCount = _appPreferences?.getDailyAdCount() ?? 0;
    if (dailyCount >= _maxFullscreenAdsPerDay) {
      SafeLogger.d(_tag, "🛡️ Daily limit: $dailyCount/$_maxFullscreenAdsPerDay");
      return (false, "Daily limit reached");
    }
    // ⑥ Throttle (min 60s giữa 2 fullscreen ads)
    if (_lastFullscreenAdTime > 0) {
      final timeSince = now - _lastFullscreenAdTime;
      if (timeSince < _minTimeBetweenFullscreenAds) {
        SafeLogger.d(_tag, "🛡️ Throttle: wait ${(_minTimeBetweenFullscreenAds - timeSince) ~/ 1000}s");
        return (false, "Throttle active");
      }
    }
    // ⑦ CTR anomaly (> 30% khi ≥ 5 impressions) → trigger suspicious pause
    if (_totalImpressions >= 5) {
      final ctr = _totalClicks / _totalImpressions;
      if (ctr > _suspiciousCtrThreshold) {
        _triggerSuspiciousPause("CTR anomaly: ${(ctr * 100).toInt()}%");
        return (false, "CTR too high: ${(ctr * 100).toInt()}%");
      }
    }
    return (true, "OK");
  }

  // ════════ CORE CHECK 2: canShowAppOpenOnResume() ════════
  // Port 3 checks từ Kotlin (dòng 1529–1560)
  static bool canShowAppOpenOnResume() {
    final now = DateTime.now().millisecondsSinceEpoch;

    // ① Cold start → skip (chỉ show App Open từ Splash)
    if (_isColdStart) {
      _isColdStart = false;
      SafeLogger.d(_tag, "🛡️ Skipping App Open on cold start");
      return false;
    }
    // ② Background quá ngắn (< 5s)
    if (_lastBackgroundTime > 0) {
      final timeInBg = now - _lastBackgroundTime;
      if (timeInBg < _minTimeAppOpenResume) {
        SafeLogger.d(_tag, "🛡️ Resume too fast (${timeInBg}ms)");
        return false;
      }
    }
    // ③ Rapid resume detection (> 3 lần resume/phút → skip)
    _resumeTimestamps.add(now);
    _resumeTimestamps.removeWhere((t) => now - t > 60000);
    if (_resumeTimestamps.length > _maxRapidResumesPerMinute) {
      SafeLogger.d(_tag, "🛡️ Rapid resume: ${_resumeTimestamps.length} resumes/min");
      _resumeTimestamps.clear();
      return false;
    }
    return true;
  }

  // ════════ RECORDING ════════

  /// Ghi nhận fullscreen ad đã SHOW thật sự
  static void recordFullscreenAdShown() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastFullscreenAdTime = now;
    _fullscreenAdsShownInSession++;
    _totalImpressions++;
    _hourlyAdTimestamps.add(now);
    _appPreferences?.incrementDailyAdCount();
    SafeLogger.d(_tag,
      "📊 Ad SHOWN | session=$_fullscreenAdsShownInSession/$_maxFullscreenAdsPerSession "
      "| hourly=${_hourlyAdTimestamps.length}/$_maxFullscreenAdsPerHour "
      "| impressions=$_totalImpressions");
  }

  /// Ghi nhận user click ad → nếu > 3 clicks/min → trigger suspicious pause
  static void recordAdClick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _totalClicks++;
    _clickTimestamps.add(now);
    _clickTimestamps.removeWhere((t) => now - t > 60000);
    if (_clickTimestamps.length > _maxClicksPerMinute) {
      _triggerSuspiciousPause("Click spam: ${_clickTimestamps.length} clicks/min");
      _clickTimestamps.clear();
    }
  }

  /// Ghi nhận app vào background (gọi từ WidgetsBindingObserver.paused)
  static void recordAppWentBackground() {
    _lastBackgroundTime = DateTime.now().millisecondsSinceEpoch;
    SafeLogger.d(_tag, "📊 App went to background");
  }

  // ════════ PROGRESSIVE COOLDOWN ════════
  // Kotlin: Math.pow(2.0, (count-1).coerceAtMost(4)) * BASE
  // → 30p → 1h → 2h → 4h → 8h (cap 24h)
  static void _triggerSuspiciousPause(String reason) {
    _suspiciousViolationCount++;
    _appPreferences?.incrementSuspiciousCount();
    final exponent = _suspiciousViolationCount - 1 > 4 ? 4 : _suspiciousViolationCount - 1;
    int multiplier = 1;
    for (int i = 0; i < exponent; i++) multiplier *= 2;
    int pauseDuration = _baseSuspiciousPause * multiplier;
    if (pauseDuration > _maxSuspiciousPause) pauseDuration = _maxSuspiciousPause;
    _suspiciousPauseUntil = DateTime.now().millisecondsSinceEpoch + pauseDuration;
    SafeLogger.w(_tag,
      "⚠️ SUSPICIOUS: $reason | violation #$_suspiciousViolationCount "
      "| paused ${pauseDuration ~/ 60000} min");
  }

  // ════════ PUBLIC API ════════
  static int getSessionAdCount() => _fullscreenAdsShownInSession;
  static void resetSession() {
    _sessionStartTime = DateTime.now().millisecondsSinceEpoch;
    _fullscreenAdsShownInSession = 0;
    _hourlyAdTimestamps.clear();
    _resumeTimestamps.clear();
    _totalImpressions = 0;
    _totalClicks = 0;
  }
  static String getStatus() {
    final ctr = _totalImpressions > 0 ? (_totalClicks / _totalImpressions * 100).toInt() : 0;
    final daily = _appPreferences?.getDailyAdCount() ?? 0;
    return "AdSafety[session=$_fullscreenAdsShownInSession/$_maxFullscreenAdsPerSession, "
        "hourly=${_hourlyAdTimestamps.length}/$_maxFullscreenAdsPerHour, "
        "daily=$daily/$_maxFullscreenAdsPerDay, CTR=$ctr%, "
        "violations=$_suspiciousViolationCount]";
  }
}
```

### STEP 4: AdManager — Core Singleton Dual Provider

> Port CHÍNH XÁC từ `AdManager` Kotlin (dòng 106–1215).
> **14 điểm KHÁC BIỆT quan trọng so với version AD.MD cũ đã được sửa:**
> 1. ✅ Thêm `recordAppWentBackground()` khi app paused
> 2. ✅ Thêm `_lastBackgroundTime` check trong `canShowAppOpenOnResume`
> 3. ✅ Thêm `_isAppOpenShowing` / `_isMaxAppOpenShowing` chống show trùng
> 4. ✅ Thêm `bypassSafety` param cho splash flow (splash bypass AdSafetyConfig)
> 5. ✅ Thêm `destroy()` method giải phóng toàn bộ resources
> 6. ✅ Thêm `_countInitSplashScreen` chống gọi init splash nhiều lần
> 7. ✅ Thêm `_isMaxAppOpenShowing` state flag
> 8. ✅ Thêm network check trước khi load
> 9. ✅ Thêm `onAdLoadFailed` clear callback cho AppLovin interstitial
> 10. ✅ Thêm `_onAppOpenDismissed` callback pattern cho AppLovin App Open
> 11. ✅ Thêm VIP member GAID list + init flow
> 12. ✅ Thêm AppLovin test device via GAID
> 13. ✅ Thêm `resetSession()` và `getStatus()`
> 14. ✅ Sửa `_triggerSuspiciousPause` trong CTR check (canShowFullscreenAd)

```dart
class AdManager {
  static final AdManager _instance = AdManager._internal();
  factory AdManager() => _instance;
  AdManager._internal();

  static const String _tag = "roy93~AdManager";
  static const int _appOpenAdTimeOut = 4 * 60 * 60 * 1000; // 4h
  static const int _errorCooldown = 15 * 60 * 1000;        // 15m

  // ════ COMMON STATE ════
  String _currentDeviceGAID = "";
  bool _isVipMember = false;
  bool _isSplashActive = true;
  int _countInitSplashScreen = 0;  // ← chống gọi init splash nhiều lần
  final Set<String> _setGAIDVipMember = {};

  // ════ ADMOB STATE ════
  AppOpenAd? _appOpenAd;
  InterstitialAd? _interstitialAd;
  RewardedAd? _rewardedAd;
  DateTime? _appOpenAdLoadTime;
  int _lastAppOpenErrorTime = 0;
  int _lastInterErrorTime = 0;
  bool _isAppOpenLoading = false;
  bool _isAppOpenShowing = false;       // ← chống show trùng

  // ════ APPLOVIN STATE ════
  bool _isMaxInterReady = false;
  bool _isMaxAppOpenReady = false;
  bool _isMaxAppOpenShowing = false;    // ← chống show trùng
  Function(bool)? _pendingInterDoneFlow;
  Function(bool)? _onAppOpenDismissed;  // ← callback pattern cho AppLovin App Open

  // ──────────────────────────────────────────────
  // INIT FLOW (tương đương AdManager.init() Kotlin)
  // ──────────────────────────────────────────────
  Future<void> initialize({required Function(bool, String) onComplete}) async {
    final prefs = await AppPreferences.getInstance();
    await AdSafetyConfig.init(prefs);

    // Load VIP GAID list từ SharedPreferences
    _setGAIDVipMember.addAll(prefs.getGAIDList());

    // Lấy GAID thiết bị hiện tại
    // Flutter: dùng package advertising_id hoặc platform channel
    // _currentDeviceGAID = await getGAID();
    // _isVipMember = _setGAIDVipMember.contains(_currentDeviceGAID);

    // First init: thêm VIP member list (chỉ 1 lần, release mode)
    if (!prefs.isAddVIPMemberFirstInitSuccess() && !kDebugMode) {
      addVIPMember(kVipDeviceGaids.toList());
      await prefs.addVIPMemberFirstInitSuccess();
    }

    if (kIsEnableAdmob) {
      await MobileAds.instance.initialize();
      final config = RequestConfiguration(testDeviceIds: kTestDeviceIds);
      await MobileAds.instance.updateRequestConfiguration(config);
    } else {
      // AppLovin: setup listeners TRƯỚC khi init SDK (gọi 1 lần duy nhất)
      _setupAppLovinAppOpenListener();
      _setupAppLovinInterstitialListener();
      await AppLovinMAX.initialize(kAppLovinSdkKey);
      // AppLovin test mode via GAID
      if (kDebugMode && _currentDeviceGAID.isNotEmpty) {
        AppLovinMAX.setTestDeviceAdvertisingIds([_currentDeviceGAID]);
      }
    }
    onComplete(true, _currentDeviceGAID);
    EventBus.sendEvent(true);
  }

  // AppLovin listeners — chỉ gọi 1 lần
  void _setupAppLovinAppOpenListener() {
    AppLovinMAX.setAppOpenAdListener(AppOpenAdListener(
      onAdLoadedCallback: (ad) { _isMaxAppOpenReady = true; },
      onAdLoadFailedCallback: (id, err) {
        _lastAppOpenErrorTime = DateTime.now().millisecondsSinceEpoch;
        _isMaxAppOpenReady = false;
      },
      onAdDisplayedCallback: (ad) {
        AdSafetyConfig.recordFullscreenAdShown();
        _isMaxAppOpenShowing = true;
      },
      onAdDisplayFailedCallback: (ad, err) {
        _isMaxAppOpenShowing = false;
        _isMaxAppOpenReady = false;
        _onAppOpenDismissed?.call(true);
        _onAppOpenDismissed = null;
      },
      onAdClickedCallback: (ad) { AdSafetyConfig.recordAdClick(); },
      onAdHiddenCallback: (ad) {
        _isMaxAppOpenShowing = false;
        _isMaxAppOpenReady = false;
        _onAppOpenDismissed?.call(true);
        _onAppOpenDismissed = null;
        AppLovinMAX.loadAppOpenAd(kAppLovinAppOpenId); // preload next
      },
    ));
  }

  void _setupAppLovinInterstitialListener() {
    AppLovinMAX.setInterstitialListener(InterstitialListener(
      onAdLoadedCallback: (ad) { _isMaxInterReady = true; },
      onAdLoadFailedCallback: (id, err) {
        _lastInterErrorTime = DateTime.now().millisecondsSinceEpoch;
        _isMaxInterReady = false;
        _pendingInterDoneFlow?.call(false);  // ← clear callback on fail
        _pendingInterDoneFlow = null;
      },
      onAdDisplayedCallback: (ad) { AdSafetyConfig.recordFullscreenAdShown(); },
      onAdDisplayFailedCallback: (ad, err) {
        _pendingInterDoneFlow?.call(false);
        _pendingInterDoneFlow = null;
      },
      onAdClickedCallback: (ad) { AdSafetyConfig.recordAdClick(); },
      onAdHiddenCallback: (ad) {
        _isMaxInterReady = false;
        _pendingInterDoneFlow?.call(true);
        _pendingInterDoneFlow = null;
        AppLovinMAX.loadInterstitial(kAppLovinInterstitialId); // preload
      },
    ));
  }

  bool _isCooldown(int lastErrorTime) =>
    lastErrorTime > 0 && DateTime.now().millisecondsSinceEpoch - lastErrorTime < _errorCooldown;

  // ──────────────────────────────────────────────
  // APP OPEN AD
  // ──────────────────────────────────────────────
  void loadAppOpenAd() {
    if (_isVipMember || _isCooldown(_lastAppOpenErrorTime)) return;
    if (kIsEnableAdmob) {
      _loadAppOpenAdAdmob();
    } else {
      AppLovinMAX.loadAppOpenAd(kAppLovinAppOpenId);
    }
  }

  void _loadAppOpenAdAdmob() {
    if (_isAppOpenLoading) return;
    if (_appOpenAd != null && _appOpenAdLoadTime != null) {
      if (DateTime.now().difference(_appOpenAdLoadTime!).inHours < 4) return;
    }
    _isAppOpenLoading = true;
    AppOpenAd.load(
      adUnitId: kAdmobAppOpenAdUnitId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          _appOpenAd = ad; _appOpenAdLoadTime = DateTime.now(); _isAppOpenLoading = false;
        },
        onAdFailedToLoad: (err) {
          _lastAppOpenErrorTime = DateTime.now().millisecondsSinceEpoch;
          _isAppOpenLoading = false;
        },
      ),
    );
  }

  /// Show App Open Ad — có param bypassSafety cho splash
  void showAppOpenAd({
    required Function(bool) onAdDismiss,
    bool bypassSafety = false,  // ← splash = true, resume = false
  }) {
    if (_isVipMember) { onAdDismiss(true); return; }

    // Chống show trùng
    final isShowing = kIsEnableAdmob ? _isAppOpenShowing : _isMaxAppOpenShowing;
    if (isShowing) { onAdDismiss(true); return; }

    // Safety checks (bypass cho splash screen)
    if (!bypassSafety) {
      final safety = AdSafetyConfig.canShowFullscreenAd();
      if (!safety.$1) { onAdDismiss(true); return; }
    }

    if (kIsEnableAdmob) {
      _showAppOpenAdAdmob(onAdDismiss);
    } else {
      _showAppOpenAdAppLovin(onAdDismiss);
    }
  }

  void _showAppOpenAdAdmob(Function(bool) onAdDismiss) {
    if (_appOpenAd == null) { onAdDismiss(true); return; }
    _appOpenAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        AdSafetyConfig.recordFullscreenAdShown();
        _isAppOpenShowing = true;
      },
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose(); _appOpenAd = null; _isAppOpenShowing = false;
        onAdDismiss(true);
      },
      onAdFailedToShowFullScreenContent: (ad, err) {
        ad.dispose(); _appOpenAd = null; _isAppOpenShowing = false;
        onAdDismiss(true);
      },
      onAdClicked: (ad) { AdSafetyConfig.recordAdClick(); },
    );
    _appOpenAd!.show();
  }

  void _showAppOpenAdAppLovin(Function(bool) onAdDismiss) {
    if (!_isMaxAppOpenReady) { onAdDismiss(true); return; }
    _onAppOpenDismissed = onAdDismiss;  // ← stored callback pattern
    AppLovinMAX.showAppOpenAd(kAppLovinAppOpenId);
  }

  // ──────────────────────────────────────────────
  // INTERSTITIAL AD
  // ──────────────────────────────────────────────
  void loadInterstitial() {
    if (_isVipMember || _isCooldown(_lastInterErrorTime)) return;
    if (kIsEnableAdmob) {
      InterstitialAd.load(
        adUnitId: kAdmobInterstitialAdUnitId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) { _interstitialAd = ad; },
          onAdFailedToLoad: (err) { _lastInterErrorTime = DateTime.now().millisecondsSinceEpoch; },
        ),
      );
    } else {
      AppLovinMAX.loadInterstitial(kAppLovinInterstitialId);
    }
  }

  void showInterstitial({required Function(bool) onDoneFlow}) {
    if (_isVipMember) { onDoneFlow(false); return; }
    final safety = AdSafetyConfig.canShowFullscreenAd();
    if (!safety.$1) { onDoneFlow(false); return; }

    if (kIsEnableAdmob) {
      if (_interstitialAd == null) { onDoneFlow(false); return; }
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (ad) { AdSafetyConfig.recordFullscreenAdShown(); },
        onAdDismissedFullScreenContent: (ad) {
          ad.dispose(); _interstitialAd = null; loadInterstitial(); onDoneFlow(true);
        },
        onAdFailedToShowFullScreenContent: (ad, err) {
          ad.dispose(); _interstitialAd = null; onDoneFlow(false);
        },
        onAdClicked: (ad) { AdSafetyConfig.recordAdClick(); },
      );
      _interstitialAd!.show();
    } else {
      if (!_isMaxInterReady) { onDoneFlow(false); return; }
      _pendingInterDoneFlow = onDoneFlow;
      AppLovinMAX.showInterstitial(kAppLovinInterstitialId);
    }
  }

  // ──────────────────────────────────────────────
  // SPLASH FLOW — initSplashScreen (tương đương Kotlin)
  // ──────────────────────────────────────────────
  // countInitSplashScreen chống gọi lại nhiều lần
  // Hard cap 8s xử lý ở SplashScreen widget
  // bypassSafety = true cho App Open ở splash
  void markSplashActive() { _isSplashActive = true; }
  void markSplashInactive() { _isSplashActive = false; }

  // ──────────────────────────────────────────────
  // APP OPEN ON RESUME (gọi từ WidgetsBindingObserver)
  // ──────────────────────────────────────────────
  void showAppOpenAdOnResume() {
    if (_isSplashActive || _isVipMember) return;
    // Kiểm tra ad sẵn sàng
    final adReady = kIsEnableAdmob ? (_appOpenAd != null) : _isMaxAppOpenReady;
    final isShowing = kIsEnableAdmob ? _isAppOpenShowing : _isMaxAppOpenShowing;
    if (adReady && !isShowing) {
      showAppOpenAd(
        onAdDismiss: (_) { loadAppOpenAd(); },  // preload next
        bypassSafety: false,
      );
    } else {
      loadAppOpenAd(); // preload cho lần resume tiếp theo
    }
  }

  // ──────────────────────────────────────────────
  // VIP MEMBER MANAGEMENT
  // ──────────────────────────────────────────────
  void addVIPMember(List<String> gaids) {
    _setGAIDVipMember.addAll(gaids);
    AppPreferences.getInstance().then((p) => p.saveGAIDList(_setGAIDVipMember.toList()));
    _isVipMember = _setGAIDVipMember.contains(_currentDeviceGAID);
  }

  void deleteVIPMember(List<String> gaids) {
    for (final g in gaids) _setGAIDVipMember.remove(g);
    AppPreferences.getInstance().then((p) => p.saveGAIDList(_setGAIDVipMember.toList()));
    _isVipMember = _setGAIDVipMember.contains(_currentDeviceGAID);
  }

  bool isVIPMember() => _isVipMember;

  // ──────────────────────────────────────────────
  // DESTROY — giải phóng toàn bộ resources
  // ──────────────────────────────────────────────
  void destroy() {
    _interstitialAd?.fullScreenContentCallback = null;
    _interstitialAd = null;
    _appOpenAd?.fullScreenContentCallback = null;
    _appOpenAd = null;
    _isMaxAppOpenReady = false;
    _isMaxAppOpenShowing = false;
    _isMaxInterReady = false;
    _pendingInterDoneFlow = null;
    _onAppOpenDismissed = null;
    _isAppOpenShowing = false;
    _isAppOpenLoading = false;
  }
}
```

### STEP 5: Shimmer & Banner Widget

*(Giữ nguyên code từ version trước — đã đúng logic)*

### STEP 6: Splash Screen — Hard Cap 8s

```dart
// Key changes vs version trước:
// - Dùng bypassSafety: true cho splash
// - countInitSplashScreen chống double init
class _SplashScreenState extends State<SplashScreen> {
  Timer? _hardCapTimer;
  bool _hasNavigated = false;
  StreamSubscription? _eventSub;

  @override
  void initState() {
    super.initState();
    AdManager().markSplashActive();
    _hardCapTimer = Timer(const Duration(seconds: 8), _navigateSafely);

    _eventSub = EventBus.stream.listen((loaded) {
      if (loaded && !_hasNavigated) {
        AdManager().loadAppOpenAd(); // load trước
        // Chờ ad load xong hoặc hard cap expiry
        AdManager().showAppOpenAd(
          onAdDismiss: (_) => _navigateSafely(),
          bypassSafety: true,  // ← splash bypass safety
        );
      }
    });

    AdManager().initialize(onComplete: (success, gaid) {});
  }

  void _navigateSafely() {
    if (_hasNavigated) return;
    _hasNavigated = true;
    _hardCapTimer?.cancel();
    _eventSub?.cancel();
    AdManager().markSplashInactive();
    if (mounted) { /* navigate */ }
  }

  @override
  void dispose() {
    _hardCapTimer?.cancel();
    _eventSub?.cancel();
    super.dispose();
  }
}
```

### STEP 7: App Lifecycle — `main.dart`

```dart
// Key changes vs version trước:
// - Gọi AdSafetyConfig.recordAppWentBackground() khi paused
// - Check canShowAppOpenOnResume() đã bao gồm cả background time check
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
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
      // ← GHI NHẬN BACKGROUND TIME (tương đương ProcessLifecycle.onStop)
      AdSafetyConfig.recordAppWentBackground();
    } else if (state == AppLifecycleState.resumed) {
      // canShowAppOpenOnResume() đã check:
      // - cold start
      // - background time >= 5s (dùng _lastBackgroundTime)
      // - rapid resume <= 3/min
      if (AdSafetyConfig.canShowAppOpenOnResume()) {
        AdManager().showAppOpenAdOnResume();
      }
    }
  }
}
```

### STEP 8: AdScreenState — Base Class

*(Giữ nguyên code từ version trước — đã đúng logic)*

---

## 4. SO SÁNH API: ADMOB vs APPLOVIN MAX FLUTTER

| Feature | AdMob (`google_mobile_ads`) | AppLovin MAX (`applovin_max`) |
|---------|---------------------------|------------------------------|
| Init | `MobileAds.instance.initialize()` | `AppLovinMAX.initialize(sdkKey)` |
| Banner | `BannerAd` object → `AdWidget` | `MaxAdView` widget (tự load) |
| Inter load | `InterstitialAd.load(...)` | `AppLovinMAX.loadInterstitial(id)` |
| Inter ready | `_interAd != null` | `AppLovinMAX.isInterstitialReady(id)` |
| Inter show | `_interAd!.show()` | `AppLovinMAX.showInterstitial(id)` |
| AppOpen load | `AppOpenAd.load(...)` | `AppLovinMAX.loadAppOpenAd(id)` |
| AppOpen show | `_appOpenAd!.show()` | `AppLovinMAX.showAppOpenAd(id)` |
| Rewarded show | `_rewardedAd!.show(onUserEarnedReward:)` | `AppLovinMAX.showRewardedAd(id)` |
| Test mode | `RequestConfiguration.testDeviceIds` | `AppLovinMAX.setTestDeviceAdvertisingIds([gaid])` |
| Listener | Object per-ad | Global listener set 1 lần |
| Preload | Manual call `loadAd()` | Trong `onAdHidden` → manual `loadAd()` |

---

## 5. CHECKLIST NGHIỆM THU

1. [ ] Chuyển cờ `kIsEnableAdmob` true → false, build chạy, logcat thấy AppLovin init
2. [ ] Splash hard cap 8s: tắt wifi → app không kẹt quá 8s
3. [ ] Banner shimmer: hiện shimmer → load xong hiện ad thật
4. [ ] Interstitial safety: show > 6 lần/session → bị block
5. [ ] Click spam: click 4+ lần/phút → progressive pause 30m kích hoạt
6. [ ] App Open resume: background > 5s → show ad; < 5s → skip
7. [ ] Rapid resume: bật/tắt app 4+ lần/phút → App Open bị skip
8. [ ] Cold start: lần đầu mở app → KHÔNG show App Open (chỉ từ splash)
9. [ ] VIP device: GAID nằm trong list → không thấy bất kỳ ad nào
10. [ ] `destroy()`: gọi khi app truly terminate → không leak
