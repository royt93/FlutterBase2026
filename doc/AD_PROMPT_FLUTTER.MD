# Prompt Template: Tích hợp `applovin_admob_sdk` vào project Flutter

> Template dùng chung cho mọi project **Flutter**. Trước khi đưa cho AI, **fill hết placeholder `<...>`** ở Section 0. VIP feature là **mandatory** — mọi project phải có VIP screen + first-install grace (SDK đã build-in, không re-implement).
> UI của vip screen nên tận dụng screen có sẵn (hoặc enhance) theo /Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025/lib/mckimquyen/widget/vip/vip_screen.dart
> 
> 
> **Rule cốt lõi (áp dụng toàn bộ codebase mới sinh):**
> 1. **KHÔNG** dùng `setState` — bắt buộc `ValueNotifier<T>` + `ValueListenableBuilder` (hoặc equivalent reactive của state manager đang dùng — ưu tiên GetX `Rx<T>` + `Obx`).
> 2. **KHÔNG** dùng `!` (bang operator) — bắt buộc null-safe pattern: `if (x case final v?)`, `final v = x; if (v == null) return;`, hoặc null-coalesce `??`.
> 3. **KHÔNG** dùng `late` / `late final` — bắt buộc nullable field + init trong `initState`, đọc bằng local copy (`final c = _controller; if (c != null) ...`).
> 4. **Ưu tiên** `AdProvider.appLovin` runtime, `AdMob` chỉ làm fallback (đổi bằng cách flip 1 dòng `AdConfig.provider`).
> 5. **State management ưu tiên**: GetX (`Rx<T>` / `Obx` / `'.tr'` cho i18n / `Get.to` cho navigation). I18n key kiểu `'snake_case'.tr`.
> 6. **Logger ưu tiên**: project's `SafeLogger` (qua `AdConfig.onLog`).

---

## 0. Bối cảnh — fill trước khi chạy
Phải đọc kỹ source code ở /Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_FlutterBase2025/packages

| Field | Giá trị |
|---|---|
| Project hiện tại (cwd, absolute path) | `<PROJECT_PATH>` |
| Dart package name (từ `pubspec.yaml: name`) | `<DART_PACKAGE_NAME>` |
| State management hiện tại | `<GetX | Provider | Riverpod | Bloc | none>` (ưu tiên GetX, nếu trống → AI hỏi) |
| Default locale | `<vi_VN | en_US | ...>` (ưu tiên `vi_VN`, fallback `en_US`) |
| `applovin_admob_sdk` version | `<LATEST_STABLE_VERSION>` ← **AI fetch `https://pub.dev/api/packages/applovin_admob_sdk` hoặc `flutter pub outdated` lấy latest stable, fill ở đây trước khi chạy Step 1**. Tối thiểu `^1.0.16`. |
| Lib reference local (nếu monorepo) | `packages/ad_sdk/` |
| File spec gốc của lib | `packages/ad_sdk/README.md` (Quick start + API) + `packages/ad_sdk/CHANGELOG.md` (lịch sử feature) + `packages/ad_sdk/MIGRATION.md` |
| Sample app | `packages/ad_sdk/example/lib/main.dart` (13 demo pages, một trang một feature) |
| Build target debug | `flutter build apk --debug` (Android) + `flutter build ios --debug --no-codesign` (iOS, nếu target iOS) — cả 2 phải xanh |
| Build target release | `flutter build apk --release --analyze-size` — verify size delta < 5MB so với baseline |
| Provider chính (active runtime) | **`AdProvider.appLovin`** (ưu tiên cứng — KHÔNG đổi) |
| Provider fallback | `AdProvider.adMob` (đổi `AdConfig.provider` để swap) |
| AppLovin SDK key | `<hỏi user — dừng nếu thiếu>` (86 chars, lấy từ `dash.applovin.com → Account → Keys → SDK Key`) |
| AppLovin banner ID | `<hỏi user — dừng nếu thiếu>` |
| AppLovin interstitial ID | `<hỏi user — dừng nếu thiếu>` |
| AppLovin app open ID | `<hỏi user — dừng nếu thiếu>` |
| AppLovin rewarded ID | `<hỏi user — dừng nếu thiếu>` |
| AdMob `APPLICATION_ID` | `<hỏi user — nếu user không có AdMob account, dùng test App ID `ca-app-pub-3940256099942544~3347511713` + warning trong báo cáo cuối>` |
| AdMob banner ID | `<hỏi user — dừng nếu thiếu>` (KHÔNG dùng test ID khi user có production ID) |
| AdMob interstitial ID | `<hỏi user — dừng nếu thiếu>` |
| AdMob app open ID | `<hỏi user — dừng nếu thiếu>` |
| AdMob rewarded ID | `<hỏi user — dừng nếu thiếu>` |
| Privacy Policy URL | `<hỏi user — dừng nếu thiếu>` (sẽ nhúng vào `ConsentDialogStrings.privacyPolicyUrl` + footer VIP screen) |
| Splash hard cap (giây) | `<hỏi user, default 8>` (đồng bộ với `AdConfig.splashMaxDuration`) |
| VIP key whitelist (plain) | `<hỏi user — list dạng "KEY: <duration>", vd "LOITP_30: 30 days, LOITP_3: 3 days">` |
| Mức che giấu VIP key | Plaintext `Map<String, Duration>` trong `vip_keys.dart`. Nếu user yêu cầu, dùng Base64 layer như `_FlutterBase2025` đang làm (`utf8.decode(base64Decode(...))`). |

**Rule cứng cho Section 0**:

1. **Cả 2 bộ ID (AppLovin + AdMob) bắt buộc đầy đủ** trước khi setup `AdConfig` — `AppLovinConfig` và `AdMobConfig` đều phải non-null trong constructor (SDK constraint). Cho phép swap không cần re-build template. Nếu user nói "chỉ có AppLovin" → AI vẫn hỏi AdMob IDs riêng từng cái, không tự fill test ID khi user có ID thật.
2. **AdMob `APPLICATION_ID` exception**: nếu user không có AdMob account và xác nhận sẽ không serve AdMob ads → cho phép dùng test App ID `ca-app-pub-3940256099942544~3347511713` + ghi warning vào báo cáo cuối Step 12.
3. Bất kỳ field nào còn ghi `<hỏi user — dừng nếu thiếu>`: AI **phải hỏi user trong chat** rồi **dừng chờ trả lời**, KHÔNG tự fill placeholder, KHÔNG dùng test ID khi user có production ID, KHÔNG bỏ qua.
4. **Latest version**: AI fetch `pub.dev` API hoặc đọc `flutter pub outdated` để lấy version stable mới nhất ngay khi bắt đầu Step 1. Verify `>= 1.0.16` (minimum cứng do dependency contract).

---

## Cấm (áp dụng mọi project)

- Tự ý thêm ad slot mới ngoài các slot đã tồn tại trong code hiện tại.
- Tự ý refactor code không liên quan đến tích hợp ad.
- Tự ý nâng/hạ version SDK ngoài range đã chốt ở Section 0.
- Tự ý đổi `AdConfig.provider` từ AppLovin sang AdMob khi user chưa yêu cầu.
- Lặp lại đọc cùng 1 file > 1 lần với mục đích "double check" — review trên kết quả đã có, không re-read.
- Tự thêm trigger interstitial mới (vd "show sau mỗi action X") nếu code cũ chưa có.
- Tự fill ad ID bằng test ID hoặc placeholder khi user đã có production ID — phải hỏi user.
- Bypass `AdSafetyParams.auto` ngoài 1 chỗ duy nhất là splash App Open ad (`bypassSafety: true`).
- Re-implement first-install VIP grace trong app code — SDK đã có `firstInstallVipGrace: FirstInstallVipGrace.auto` (30s debug / 24h release). **Mandate dùng `auto`, KHÔNG override**.
- Show App Open Ad **trên splash thuần** (vi phạm AdMob policy "Disallowed interstitial implementations") — phải qua flow `loadAppOpenAd → AdLoadingDialog.showAdBuffer → showAppOpenAd(bypassSafety: true)`.
- Tự subscribe `WidgetsBindingObserver` lifecycle để show App Open trên resume — SDK đã hook sẵn, double-subscribe = double-show.
- Tự thêm permission Android/iOS ngoài whitelist (xem Step 2 + Step 11), trừ permission **liên quan ad** với lý do rõ ràng (vd `ACCESS_WIFI_STATE` cho AppLovin GeoTargeting). Permission ngoài ad → hỏi user trước.
- **Dùng `setState`, `!` (bang operator), `late` / `late final`** — vi phạm 3 rule cốt lõi ở đầu file. Step 11 sẽ grep + reject nếu phát hiện.
- Hard-code user-facing strings (consent dialog, VIP UI, disclaimer) — bắt buộc qua `'snake_case_key'.tr` (GetX) và thêm key vào `vi_vn.dart` + `en_us.dart`.

---

## Step 1 — Đọc lib reference

- `ls` đệ quy `packages/ad_sdk/` (nếu monorepo) hoặc `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<VERSION>/` (nếu hosted).
- Fetch `https://pub.dev/api/packages/applovin_admob_sdk` để verify latest stable, update Section 0 nếu cần.
- Đọc `packages/ad_sdk/README.md` (Quick start + Configuration reference + Public API). Đặc biệt các call site:
  - Bootstrap: `AdManager().setNavigatorKey(key)`, `adRouteObserver`, `AdScreenRouteLogger()`, `SimpleEventBus().listen`, `AdManager().initialize(config:, onComplete:)`.
  - Splash flow: `markSplashActive` / `markSplashInactive` / `incrementSplashCount` / `countInitSplashScreen`, `loadAppOpenAd`, `AdLoadingDialog.showAdBuffer`, `showAppOpenAd(bypassSafety: true)`.
  - Per-screen: `class XxxScreen extends AdScreen` → `class _XxxState extends AdScreenState<XxxScreen>` cấp `buildBanner()`, `showInterstitialAd(onDone:)`, `showRewardedAd(onEarnedReward:)`.
  - VIP: `AdManager().vip` (nullable!) → `addVip / redeemVip / revokeVip / revokeAll / activeListenable / activeStream / expiresAt / entries`.
  - Consent: `AdManager().requestUmpConsent(testMode:, debugGeography:, testIdentifiers:)` + `ConsentManager.instance.showDialog(context)` + `AdConfig.autoShowConsentDialog` + `consentDialogStrings`.
  - Safety: `AdSafetyParams.auto` (default, KHÔNG override).
  - Logger pipe: `AdConfig.onLog: (level, tag, msg) { ... }`.
- Đọc `packages/ad_sdk/CHANGELOG.md` — phần "What's new" cho version đang dùng để biết feature mới (UMP wrapper, smart App-Open timeout, slot-state dismiss watcher, first-install grace, anti-bypass nếu có ở version đó, taskAffinity pitfall).
- Đọc `packages/ad_sdk/example/lib/main.dart` để xem demo page nào active.

**Output bắt buộc**: 1 đoạn ≤ 10 dòng tóm tắt API surface của lib và những thứ SDK tự quản (App Open auto qua `WidgetsBindingObserver`, banner auto pause/resume qua `adRouteObserver` + RouteAware, frequency cap qua 12-layer safety gate, VIP auto-expire `Timer`, consent dialog auto-show post-splash 1s, first-install grace, anti-bypass nếu version đó có).

## Step 2 — Audit hiện trạng project

Trả lời 8 câu (yes/no + dẫn chứng `file:line`):

1. Project đã apply `applovin_admob_sdk` chưa? Hay vẫn còn SDK cũ (vd `google_mobile_ads` raw, custom `AdMobManager`, `AdsHelper`…)?
2. `main.dart` đang gọi gì để init? Có `AdManager().setNavigatorKey(navigatorKey)` **trước** `runApp` không? Có `adRouteObserver` + `AdScreenRouteLogger()` trong `navigatorObservers` không?
3. Splash screen có gọi `AdManager().initialize` (KHÔNG phải `main`)? Có `SimpleEventBus().listen` đăng ký **trước** `initialize` không? Có hard-cap timer + hot-restart guard (`countInitSplashScreen > 1`) không?
4. Screen nào đang load banner / interstitial / rewarded bằng API nào? Đã extend `AdScreen` chưa?
5. **Đã có VIP screen chưa?** Nếu có → AI sẽ **upgrade in-place** ở Step 10. Nếu chưa → tạo mới. Mô tả UI hiện tại nếu có.
6. State management: project đang dùng GetX / Provider / Riverpod / Bloc / setState? Verify GetX có sẵn (`pubspec.yaml`) chưa — nếu chưa → AI sẽ thêm theo Q37.
7. Project có `BaseStatefulState` (hoặc `BaseStatefulWidget`, `BaseScreen` tương đương) không? Vị trí? Helper gì sẵn (alert dialog, lifecycle log)? Nếu chưa có → AI sẽ tạo mới ở `lib/<DART_PACKAGE_NAME>/core/base_stateful_state.dart`.
8. Project có `SafeLogger` (hoặc `Logger`, `Talker`, `LogUtils` tương đương) không? Vị trí? Method (`d`/`i`/`w`/`e`)? Nếu chưa có → AI sẽ tạo mới ở `lib/<DART_PACKAGE_NAME>/util/safe_logger.dart`.

## Step 3 — Viết kế hoạch tích hợp vào `<PROJECT_PATH>/doc/AD.MD`

File đích: `<PROJECT_PATH>/doc/AD.MD` (tạo mới nếu chưa có; project `_FlutterBase2025` đã có file mẫu).

Bắt buộc có các section:

**(1) Touchpoint table** — mỗi slot 1 dòng. Nếu slot chưa tồn tại trong project, ghi `(chưa có)` ở cột "API cũ thay thế":

| Slot | File hiện tại | Trigger | API mới | API cũ thay thế |
|---|---|---|---|---|
| Banner | `<host screen>.dart` | `build()` của screen extend `AdScreen` | `buildBanner()` (wrap edge-to-edge — Step 4) | `<API cũ hoặc (chưa có)>` |
| Interstitial | `<host screen>.dart` | `<trigger giữ nguyên>` | `showInterstitialAd(onDone: (shown) {...})` | `<API cũ>` |
| App Open (cold) | Splash | sau `initialize` + `loadAppOpenAd` + `AdLoadingDialog.showAdBuffer` | `showAppOpenAd(bypassSafety: true, onAdDismiss:)` | `<API cũ hoặc (chưa có)>` |
| App Open (resume) | SDK auto | `WidgetsBindingObserver` (SDK internal) | (không gọi thủ công) | `<API cũ hoặc (chưa có)>` |
| Rewarded | VIP screen / clear-history button / etc. | user click | `showRewardedAd(onEarnedReward: (earned) {...})` | `<API cũ hoặc (chưa có)>` |

**(2) Step-by-step plan** — 6 bước (Setup pubspec + native config, App init wiring + Consent + ATT, Splash flow, VIP UI + AdKey + i18n, Banner placement edge-to-edge, Interstitial/Rewarded triggers). Mỗi bước nói rõ file edit, hàm thêm, dòng xoá.

**(3) Bảng so sánh trước/sau** — tối thiểu 8 dòng (Provider, Architecture, App Open lifecycle, Consent UI + UMP, Memory leak risk, Frequency cap, VIP support, Banner pause/resume).

**(4) Thông tin cần user cấp** — list rõ những gì còn thiếu: ad unit ID, AppLovin SDK key, Privacy Policy URL, banner placement layout (top/bottom/anchored — default bottom), VIP key whitelist + duration mapping, splash hard-cap.

## Step 4 — Lifecycle requirement (rule cứng, áp dụng mọi project Flutter)

### 4.1 — Bootstrap order trong `main.dart` (KHÔNG đổi thứ tự)

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. setNavigatorKey TRƯỚC runApp — bắt buộc
  AdManager().setNavigatorKey(navigatorKey);

  // 2. (iOS only) ATT prompt nếu target iOS — Step 8.iOS
  // if (Platform.isIOS) await AppTrackingTransparency.requestTrackingAuthorization();

  // 3. Project bootstrap (wakelock, edge-to-edge, refresh rate)
  WakelockPlus.enable();
  UIUtils.initEdgeToEdge();
  if (Platform.isAndroid) await FlutterDisplayMode.setHighRefreshRate();

  // 4. State manager init
  Get.put(ControllerMain());

  // 5. Locale
  final savedLocale = await LanguageService.getSavedLanguage();

  // 6. runApp với navigator + 2 observers
  runApp(GetMaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    translations: AppTranslations(),
    locale: savedLocale ?? const Locale('vi', 'VN'),
    fallbackLocale: const Locale('en', 'US'),
    home: const SplashScreen(),
  ));
}
```

Nếu thiếu `setNavigatorKey`, auto-show consent dialog và app-open-on-resume buffer sẽ silent fail.

### 4.2 — Splash flow (rule cứng, mandate hot-restart guard)

```dart
class _SplashScreenState extends BaseStatefulState<SplashScreen> {
  Timer? _hardCap;
  StreamSubscription<BoolEvent>? _busSub;
  final ValueNotifier<bool> _navigated = ValueNotifier(false);

  @override
  void initState() {
    super.initState();

    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // 4.2.1 — Hot-restart guard (mandate)
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }

    // 4.2.2 — Hard cap timer (default 8s, đồng bộ với AdConfig.splashMaxDuration)
    _hardCap = Timer(const Duration(seconds: 8), _goHome);

    // 4.2.3 — Subscribe TRƯỚC initialize
    _busSub = SimpleEventBus().listen<BoolEvent>((e) {
      if (e.value) {
        _showSplashAppOpen();
      } else {
        _goHome();
      }
    });

    // 4.2.4 — UMP TRƯỚC initialize (Step 8 Option B)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await AdManager().requestUmpConsent(testMode: kDebugMode);
      } catch (e) {
        SafeLogger.w('Splash', 'UMP threw, continuing init anyway: $e');
      }
      AdManager().initialize(
        config: AdConfig(
          provider: AdProvider.appLovin,                  // RULE #4 ưu tiên
          appLovin: AdKey.appLovin,                       // RULE #16 AdKey class
          adMob: AdKey.adMob,
          // firstInstallVipGrace: FirstInstallVipGrace.auto,  // default — KHÔNG override
          // autoShowConsentDialog: true,                       // default
          consentDialogStrings: ConsentDialogStrings(
            title: 'consent_title'.tr,
            message: 'consent_message'.tr,
            allowButton: 'consent_allow'.tr,
            rejectButton: 'consent_reject'.tr,
            privacyPolicyLabel: 'consent_privacy_label'.tr,
            privacyPolicyUrl: AdKey.privacyPolicyUrl,
          ),
          vipKeyValidator: vipKeyValidator,
          vipDialogStrings: VipDialogStrings(
            verifyingTitle: 'vip_verifying_title'.tr,
            successTitle: 'vip_success_title'.tr,
            failedTitle: 'vip_failed_title'.tr,
            // ... full strings
          ),
          logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,
          onLog: (level, tag, msg) {
            switch (level) {
              case AdLogLevel.error:   SafeLogger.e(tag, msg); break;
              case AdLogLevel.warning: SafeLogger.w(tag, msg); break;
              default:                  SafeLogger.d(tag, msg);
            }
          },
        ),
      );
    });
  }

  void _showSplashAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated.value || !mounted) return;
      if (!loaded) return _goHome();
      AdLoadingDialog.showAdBuffer(context, onComplete: () {
        if (!mounted) return _goHome();
        // Cancel hard-cap TRƯỚC showAppOpenAd
        _hardCap?.cancel();
        _hardCap = null;
        AdManager().showAppOpenAd(
          bypassSafety: true,                   // CHỈ CHỖ NÀY được bypass
          onAdDismiss: (_) => _goHome(),
        );
      });
    });
  }

  void _goHome() {
    if (_navigated.value) return;
    _navigated.value = true;
    _hardCap?.cancel();
    _hardCap = null;
    AdManager().markSplashInactive();
    if (!mounted) return;
    Get.offAll(() => const MainScreen());
  }

  @override
  void dispose() {
    _hardCap?.cancel();
    _busSub?.cancel();
    _navigated.dispose();
    super.dispose();
  }
}
```

### 4.3 — Splash UI (mandate disclaimer — Q27)

Trên splash phải có text disclaimer trước khi App Open Ad show:

```dart
Text(
  'splash_ads_notice'.tr,    // i18n key bắt buộc
  textAlign: TextAlign.center,
  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
)
LinearProgressIndicator(...)
```

Translations bắt buộc thêm:
```dart
// vi_vn.dart
'splash_ads_notice': 'Lưu ý: ứng dụng có thể hiển thị quảng cáo',
// en_us.dart
'splash_ads_notice': 'Please note: this action may show ads',
```

### 4.4 — Banner: extend `AdScreen` + edge-to-edge

```dart
class HomeScreen extends AdScreen {  // KHÔNG StatefulWidget
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(child: _content()),
        _buildBannerEdgeToEdge(),    // bottom + edge-to-edge wrap
      ],
    ),
  );

  // Detect edge-to-edge (Q23 D): nếu app dùng UIUtils.initEdgeToEdge() →
  // wrap với SafeArea(top: false, bottom: true) để banner ngồi trên gesture nav bar.
  // Nếu app KHÔNG edge-to-edge → buildBanner() trần thoải mái.
  Widget _buildBannerEdgeToEdge() {
    return SafeArea(
      top: false,
      bottom: true,
      child: buildBanner(),
    );
  }
}
```

### 4.5 — App Open khi quay lại foreground

SDK đã hook `WidgetsBindingObserver`. **KHÔNG** tự subscribe lifecycle lần thứ 2 — tránh double-show.

### 4.6 — Interstitial pattern

```dart
showInterstitialAd(onDone: (shown) {
  // shown=true → ad displayed and dismissed
  // shown=false → blocked by safety / VIP / no network / slot showing
  // ALWAYS execute the post-action regardless (navigate, etc.)
  Get.to(() => const HistoryScreen());
});
```

### 4.7 — Rewarded pattern

Chỉ load + show khi user bấm nút (vd VIP screen "Watch ad → 3 days VIP", clear history, unlock feature):

```dart
showRewardedAd(onEarnedReward: (earned) {
  if (!earned) return;
  // grant reward (vd grant VIP 3 ngày)
  final vip = AdManager().vip;     // RULE #2 no `!`
  if (vip == null) return;
  vip.addVip(key: 'REWARDED_${DateTime.now().millisecondsSinceEpoch}', duration: const Duration(days: 3));
});
```

## Step 5 — Phạm vi thay thế (mandate replace all — Q11)

Project có SDK ad cũ → **bắt buộc replace toàn bộ** sang `applovin_admob_sdk`. Không coexist.

Trước khi xoá file/class SDK cũ, **grep verify** không còn ai dùng:

- Liệt kê file SDK cũ sẽ xoá (vd `lib/utils/ad_helper.dart`, `lib/services/admob_service.dart`, custom `AdMobManager`…).
- Với mỗi file: `grep -r 'ClassName\|methodName' lib/` toàn project, xác nhận 0 reference, rồi mới xoá.
- Xoá deps cũ trong `pubspec.yaml` (`google_mobile_ads`, `applovin_max`, `unity_ads`, etc.) trừ `gma_mediation_applovin` (bắt buộc app-level cho native mediation, KHÔNG xoá).
- Không tự thêm banner/interstitial/rewarded ở screen khác ngoài chỗ SDK cũ đã có.

## Step 6 — Build & memory check

### 6.1 — Build

- `flutter analyze --fatal-infos` → 0 issue (mandate Q10)
- `flutter build apk --debug` → xanh
- `flutter build apk --release --analyze-size` → xanh, size delta < 5MB
- (Nếu target iOS) `flutter build ios --debug --no-codesign` → xanh

### 6.2 — Memory leak review (4 điểm thủ công)

- Screen extend `AdScreen` có `super.dispose()` đúng cuối `dispose()` không?
- VIP screen có cancel toàn bộ `Timer`, `AnimationController`, `StreamSubscription`, `TextEditingController.dispose()`, `FocusNode.dispose()`, `ValueNotifier.dispose()` trong `dispose()` không?
- Splash có `_hardCap?.cancel()` + `_busSub?.cancel()` + `_navigated.dispose()` trong `dispose()` không?
- `MaterialApp.navigatorKey` có giữ stale reference sau hot-restart không?

Output: bảng "điểm review / kết luận / `file:line` dẫn chứng".

## Step 7 — Policy check (5 rule cụ thể)

| # | Rule | Cách verify |
|---|---|---|
| 1 | Banner không che nội dung tương tác, edge-to-edge wrap đúng | Đọc layout host banner + verify SafeArea/Padding theo Step 4.4 |
| 2 | App Open không show trên splash thuần — chỉ show sau loading buffer (`AdLoadingDialog.showAdBuffer`) trước khi navigate sang main, hoặc khi resume từ background (SDK auto) | Đọc Splash screen + verify flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` |
| 3 | Interstitial không show liên tiếp dưới ngưỡng frequency cap | Tin `AdSafetyParams.auto` mặc định, ghi rõ giá trị (production: throttle 60s, session cap 6, hourly 3, daily 5) |
| 4 | Rewarded chỉ trigger khi user bấm nút | Đọc VIP screen + bất kỳ trigger rewarded nào khác |
| 5 | Disclaimer "may show ads" hiển thị trên Splash trước App Open | Đọc Splash UI |

Báo cáo: PASS/FAIL từng rule + `file:line` dẫn chứng.

## Step 8 — Consent (UMP + auto-show dialog + iOS ATT)

Wire **cả** 3:

### 8.1 — Cupertino auto-show dialog (default ON)

Strings qua i18n `.tr` (Step 4.2 đã wire). Auto-show ~1s sau `markSplashInactive`. Skip điều kiện (auto): VIP active, `hasBeenAsked == true`, không có `navigatorKey`. Re-show từ Privacy settings: `await ConsentManager.instance.showDialog(context)`.

### 8.2 — Google UMP form (mandate)

Đã gọi ở splash trước `initialize()` (Step 4.2.4). Test scenario tối thiểu cần ghi nhận trong báo cáo (KHÔNG cần chạy thực):
- Non-EEA: skip dialog, ad load bình thường.
- EEA, lần đầu: UMP form Google show → user chọn → cached ở `SharedPreferences`.
- EEA, không internet: `requestConsentInfoUpdate` fail → catch → continue init.

### 8.3 — iOS ATT (mandate, Q14A)

Nếu project target iOS:

- Add dep `app_tracking_transparency: <LATEST>` vào `pubspec.yaml`.
- Add `Info.plist` key `NSUserTrackingUsageDescription`:
  ```xml
  <key>NSUserTrackingUsageDescription</key>
  <string>This identifier is used to deliver personalised ads.</string>
  ```
- Trong `main.dart` TRƯỚC `AdManager().initialize` (cụ thể trước Step 4.2.4):
  ```dart
  if (Platform.isIOS) {
    await AppTrackingTransparency.requestTrackingAuthorization();
  }
  ```
- iOS 14.5+ KHÔNG show ATT prompt = AppLovin/AdMob fallback non-personalized ads.

## Step 9 — First-install VIP grace + Anti-uninstall-bypass guard

### 9.1 — Grace config (SDK built-in, KHÔNG override)

**KHÔNG** lưu flag `pref_first_launch_vip_granted` thủ công, **KHÔNG** gọi `vip.addVip(...)` trong `main()` để grant 1 ngày — SDK đã có `firstInstallVipGrace` mặc định `auto` (30s debug / 24h release).

```dart
AdConfig(
  // firstInstallVipGrace: FirstInstallVipGrace.auto,  // default — KHÔNG override (Q34)
  // firstInstallVipKey: '__FIRST_INSTALL__',          // default
)
```

Verify ở entry `__FIRST_INSTALL__` trong `vip.entries` sau init lần đầu (xem Step 10.6 — special entries).

### 9.2 — Anti-uninstall-bypass guard (SDK ≥ 1.0.17, latest 1.0.18)

Mục tiêu: chặn user gỡ app + cài lại để nhận grace 24h vô hạn lần. Cơ chế per platform:

| Platform | Mechanism | AI cần làm gì? |
|---|---|---|
| **iOS** | SDK auto: ghi flag vào Keychain via `flutter_secure_storage`. Keychain persist qua uninstall by default. | ✅ Không làm gì (SDK tự handle) |
| **Android** | **Host-app config**: AndroidManifest + 2 file XML để Auto Backup khôi phục `FlutterSharedPreferences.xml` qua reinstall cùng Google account. | ⚠️ **AI BẮT BUỘC config** (xem 9.3) |

Hạn chế đã accept (documented):
- Android: bypass nếu uninstall trong 24h đầu (Auto Backup chưa kịp chạy), hoặc user disable Backup, hoặc cross-account, hoặc factory reset. ~5-15% edge cases.
- iOS: bypass chỉ khi "Erase All Content and Settings" hoặc encrypted backup restore lên device khác.

### 9.3 — Android Auto Backup config (BẮT BUỘC nếu host target Android)

**(a) `android/app/src/main/AndroidManifest.xml`** — thêm 3 attribute vào `<application>`:

```xml
<application
    android:name="${applicationName}"
    android:allowBackup="true"
    android:fullBackupContent="@xml/full_backup_content"
    android:dataExtractionRules="@xml/data_extraction_rules"
    ...>
```

Giải thích từng attribute:
- `android:allowBackup="true"` — bật Google Auto Backup feature (BẮT BUỘC).
- `android:fullBackupContent="@xml/full_backup_content"` — legacy rules cho Android 6-11 (API 23-30).
- `android:dataExtractionRules="@xml/data_extraction_rules"` — modern rules cho Android 12+ (API 31+).

Nếu host app đang có `android:allowBackup="false"` → AI **phải hỏi user trước khi đổi** (có thể họ tắt vì compliance/privacy reason). Nếu user xác nhận đổi → set `true`.

**(b) `android/app/src/main/res/xml/data_extraction_rules.xml`** — Android 12+ (target SDK ≥ 31), bắt buộc tạo file mới:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  Auto Backup + Device Transfer rules required by applovin_admob_sdk
  anti-uninstall-bypass guard. The first-install grace flag in
  FlutterSharedPreferences.xml must be cloud-backed up so a reinstall
  on the same Google account restores the flag and skips re-granting
  a fresh 24h grace window.

  Excludes FlutterSecureStorage.xml because EncryptedSharedPreferences
  ciphertext is unrecoverable without the device-bound Keystore key.
-->
<data-extraction-rules>
    <cloud-backup>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
        <exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
    </cloud-backup>
    <device-transfer>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
        <exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
    </device-transfer>
</data-extraction-rules>
```

**(c) `android/app/src/main/res/xml/full_backup_content.xml`** — Android 6-11 legacy, bắt buộc tạo file mới:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  Legacy Auto Backup rules (Android 6-11, API 23-30).
  Replaced by data_extraction_rules.xml on API 31+.
  Same intent: include host SharedPreferences (where the SDK first-install
  grace flag lives), exclude EncryptedSharedPreferences ciphertext.
-->
<full-backup-content>
    <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
    <exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
</full-backup-content>
```

**Note**: Cả 2 file `data_extraction_rules.xml` và `full_backup_content.xml` đều cần — Android pick file phù hợp dựa trên runtime API level. Không thể dùng 1 trong 2.

**Verify**: nếu host app đã có `res/xml/` directory với file backup khác (vd cho Firebase, Hive backup), AI **phải merge include/exclude entries** thay vì overwrite.

### 9.4 — iOS — KHÔNG cần config gì thêm

SDK tự handle Keychain. Default `flutter_secure_storage` settings (`kSecAttrAccessibleAfterFirstUnlock`, no `synchronizable`, no `kSecAttrAccessGroup`) là chính xác cho anti-bypass. KHÔNG override.

### 9.5 — Manual smoke test anti-bypass (release builds)

**Android (Play Store internal track)**:
```bash
# 1. Build signed AAB
flutter build appbundle --release

# 2. Upload Play Console Internal Testing, install qua Play Store
# 3. Wait > 24h HOẶC trigger backup ngay:
adb shell bmgr backupnow <package_name>

# 4. Uninstall + reinstall qua Play Store
# 5. Verify log: KHÔNG có "🎁 first-install VIP grace granted" → block hoạt động
#                Hoặc app không có VIP entry __FIRST_INSTALL__ → đã skip
```

**iOS (TestFlight hoặc Xcode signed Ad Hoc)**:
```
1. Tạm sửa firstInstallVipGrace = FirstInstallVipGrace.debugShort (30s) cho fast cycle
2. Build release IPA, install qua Xcode/TestFlight
3. Verify log "🎁 first-install VIP grace granted (30s, mode=release)"
4. Đợi 30s → log "⏰ VIP entry expired"
5. Uninstall app
6. Reinstall qua Xcode/TestFlight
7. Verify log "🛡️ Keychain flag present — prior install detected on this device"
8. Verify log "🛡️ first-install VIP grace SKIPPED"
9. Restore lại firstInstallVipGrace = .auto cho production
```

## Step 10 — UI/UX VIP management screen (chi tiết, mandatory)

**VIP feature mandatory — không skip. Step 2 đã audit có hay chưa: nếu có thì upgrade in-place (project `_FlutterBase2025` đã có `lib/mckimquyen/widget/vip/vip_screen.dart` + `vip_keys.dart`), nếu chưa thì tạo mới.**

### 10.1 — File structure (mandate)

```
lib/<DART_PACKAGE_NAME>/
├── common/const/
│   ├── ad_keys.dart              ← Q21A + Q29c — class AdKey
│   └── color_constants.dart      ← (đã có trong project)
├── core/
│   └── base_stateful_state.dart  ← Q36 — detect existing or create
├── util/
│   └── safe_logger.dart          ← Q9 — detect existing or create
└── widget/
    ├── splash/splash_screen.dart
    └── vip/
        ├── vip_screen.dart       ← UI chính
        └── vip_keys.dart         ← validator + key map
```

### 10.2 — `AdKey` class (Q16A + Q21A + Q29c)

`lib/<DART_PACKAGE_NAME>/common/const/ad_keys.dart`:

```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

/// Centralised ad-related constants. Single key per project (Q25A) — không
/// switch theo flavor.
abstract final class AdKey {
  static const AppLovinConfig appLovin = AppLovinConfig(
    sdkKey:         '<APPLOVIN_SDK_KEY>',
    bannerId:       '<APPLOVIN_BANNER_ID>',
    interstitialId: '<APPLOVIN_INTERSTITIAL_ID>',
    appOpenId:      '<APPLOVIN_APP_OPEN_ID>',
    rewardedId:     '<APPLOVIN_REWARDED_ID>',
  );

  static const AdMobConfig adMob = AdMobConfig(
    bannerId:       '<ADMOB_BANNER_ID>',
    interstitialId: '<ADMOB_INTERSTITIAL_ID>',
    appOpenId:      '<ADMOB_APP_OPEN_ID>',
    rewardedId:     '<ADMOB_REWARDED_ID>',
  );

  static const String privacyPolicyUrl = '<PRIVACY_POLICY_URL>';
}
```

**Usage:** `AdManager().initialize(config: AdConfig(provider: AdProvider.appLovin, appLovin: AdKey.appLovin, adMob: AdKey.adMob, ...))`.

### 10.3 — Cấu trúc UI (bắt buộc đủ 13 thành phần — Q19A + Q33A)

| # | Thành phần | Detail (Flutter idiom, no `setState`/`!`/`late`) |
|---|---|---|
| 1 | Status header / Hero card | `ValueListenableBuilder<bool>` lắng nghe `vip?.activeListenable` (null-safe pattern). Active: gradient gold + crown icon `Icons.workspace_premium` + text 2 dòng (`'vip_active'.tr` + `'vip_until'.trParams({'date': formatted})`). Inactive: gradient xám + `'vip_free_user'.tr` |
| 2 | Activation date row | `'Activated: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.grantedAt)}'` (ẩn nếu free). Dùng `package:intl`. Field name là `grantedAt` (SDK 1.0.18+), KHÔNG phải `startedAt` |
| 3 | Expiry date row | `'Expires: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.expiresAt)}'` (ẩn nếu free) |
| 4 | Progress bar (elapsed) | `LinearProgressIndicator` với `value = (now − entry.grantedAt) / (entry.expiresAt − entry.grantedAt)`, clamp `[0.0, 1.0]`. **3 mốc trên timeline ngang**: `start = entry.grantedAt` (mép trái, 0%), `end = entry.expiresAt` (mép phải, 100%), `current = now` (vị trí thanh fill). Bar **rỗng lúc vừa kích hoạt → đầy dần đến hết hạn** (elapsed semantic — match user mental model "progression toward expiry"). Tuyệt đối KHÔNG đảo formula thành `remaining/total` (đầy → rỗng) — UX confusing. Chỉ show khi VIP active. **KHÔNG cần `TweenAnimationBuilder`** — per-second tick từ `_now` đủ smooth (Δ ≪ 0.001%/s cho VIP 24h trở lên), TweenAnimationBuilder chỉ thêm overhead và làm chậm rebuild. Edge case `total ≤ 0` (clock skew / đã expire) → default `value = 1.0` (đầy = đã hết hạn) |
| 5 | Countdown text | Dạng `12d 03h 24m 15s` — update bằng `Timer.periodic(Duration(seconds: 1), ...)` trong `initState`, `cancel()` trong `dispose`. State qua `ValueNotifier<Duration>` không qua `setState` |
| 6 | TextField nhập key VIP | `TextEditingController` + `TextCapitalization.characters` (uppercase auto), prefix icon `Icons.confirmation_number`, suffix clear button. Nút "Kích hoạt" gọi `vip.redeemVip(context, key, duration, validator, strings)` — SDK đã handle Cupertino verifying/success/failed dialogs |
| 7 | Button "Watch ad → N days VIP" | Click → `showRewardedAd(onEarnedReward: ...)`. Fallback nếu rewarded load fail: `showInterstitialAd(onDone: ...)`. Pulse animation #1 |
| 8 | Buy 30-day VIP (disabled) | `OutlinedButton.icon(icon: Icon(Icons.card_giftcard))` disabled, label `'vip_buy_30d_locked'.tr` ('Mua VIP 30 ngày — sắp ra mắt'). Wait IAP integration |
| 9 | Buy 90-day VIP (disabled) | Tương tự #8 |
| 10 | Buy 1-year VIP (disabled) | Tương tự #8 |
| 11 | Buy lifetime VIP (disabled) | Tương tự #8 |
| 12 | List active entries | `ValueListenableBuilder<List<VipEntry>>` (đăng ký từ `vip.activeStream` + local notifier). Mỗi entry 1 card với icon riêng (10.6), days/hours remaining, expires date, button revoke |
| 13 | "Restore Purchase" (disabled) | `OutlinedButton.icon(icon: Icon(Icons.restore))` disabled, label `'vip_restore_locked'.tr` ('Khôi phục mua hàng — sắp ra mắt'). Placeholder cho IAP tương lai (Q33A) |
| — | Button "Thu hồi tất cả VIP" | Material 3 `AlertDialog` confirm → `await vip.revokeAll()`. Disabled khi free user |
| — | Toolbar badge "VIP" trên main screen | `ValueListenableBuilder<bool>(valueListenable: vip.activeListenable, ...)` — active: chip vàng `0xFFFFD60A`, inactive: outline trắng |
| — | Privacy Policy footer | `InkWell` → `url_launcher.launchUrl(Uri.parse(AdKey.privacyPolicyUrl), mode: LaunchMode.externalApplication)` |

- TextField và dialog phải dùng Material 3 (`useMaterial3: true` trong `ThemeData`).
- Sau khi kích hoạt VIP thành công, UI lập tức cập nhật qua `activeListenable` reactive — KHÔNG `setState`. Kèm confetti animation (Q18A) + `HapticFeedback.heavyImpact()`.

#### Reference implementation cho row #4 (Progress bar — elapsed semantic)

```dart
/// 3 mốc trên timeline ngang [grantedAt ─── expiresAt]:
///   start   = entry.grantedAt   (mép trái, value 0.0)
///   end     = entry.expiresAt   (mép phải, value 1.0)
///   current = now               (vị trí thanh fill)
///
/// progress = (current − start) / (end − start)
/// Bar RỖNG lúc vừa kích hoạt, ĐẦY DẦN đến lúc hết hạn.
Widget _buildProgressBar(VipEntry entry) {
  return ValueListenableBuilder<DateTime>(
    valueListenable: _now,  // ticker 1s, drives elapsed update
    builder: (context, now, _) {
      final total = entry.expiresAt.difference(entry.grantedAt);
      final elapsed = now.difference(entry.grantedAt);
      final progress = total.inMilliseconds <= 0
          ? 1.0  // expired / clock skew → render đầy
          : (elapsed.inMilliseconds / total.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 10,
          backgroundColor: Colors.white.withValues(alpha: 0.18),
          valueColor: AlwaysStoppedAnimation<Color>(
            Colors.white.withValues(alpha: 0.95),
          ),
        ),
      );
    },
  );
}
```

Visualization với VIP 30 ngày:
```
T+0      [░░░░░░░░░░░░░░░░░░░░░░░░░░░]   0% — vừa redeem
T+1d     [█░░░░░░░░░░░░░░░░░░░░░░░░░░]   3.3%
T+15d    [██████████████░░░░░░░░░░░░░]   50%
T+29d    [██████████████████████████░]   96.7%
T+30d    [███████████████████████████]  100% — expired
```

### 10.4 — Animation (bắt buộc đủ 5 — Flutter idiom, no `late`)

| # | Animation | Cách impl | Trigger |
|---|---|---|---|
| 1 | Pulse cho nút "Watch ad" | `AnimationController? _pulseController;` init trong `initState` với `duration: 1600ms` `..repeat(reverse: true)`. Local copy `final c = _pulseController; if (c != null) ... ScaleTransition(scale: Tween(1.0, 1.05).animate(c), ...)` | `initState` start, `dispose` cancel |
| 2 | Slide-in từ dưới khi mở screen | `AnimationController? _entryController;` init `duration: 1100ms` `..forward()`. 3 section dùng chung 1 controller, mỗi section một `Interval(0.0, 0.4)`, `Interval(0.3, 0.7)`, `Interval(0.6, 1.0)` — fade-slide vào tuần tự | `initState` |
| 3 | Crown icon shimmer | `AnimationController? _shimmerController;` init `duration: 3000ms` `..repeat()`. `RotationTransition` ±5° HOẶC `ShaderMask` với `LinearGradient` shimmer | `initState` repeat, `dispose` cancel |
| 4 | Number count-up cho countdown | `TweenAnimationBuilder<double>` chạy khi value đổi đáng kể (mỗi phút) — KHÔNG mỗi giây để tránh build hot loop | Khi `Timer.periodic` chạm phút mới |
| 5 | Confetti khi activate thành công | `package:confetti` (Q18A): `ConfettiController? _confettiController;` init `duration: 1000ms`. Trong `dispose`: `_confettiController?.dispose()`. Khi `redeemVip` hoặc `onEarnedReward` true → `_confettiController?.play()` + `HapticFeedback.heavyImpact()` (Flutter built-in, không cần `vibration` package) | Sau success |

Bonus (nice-to-have, không bắt buộc): ripple effect mặc định cho 2 button (Material 3 sẵn), gradient background động cho status header.

### 10.5 — Memory leak rule riêng cho VIP screen (KHÔNG dùng các pattern sau)

- **KHÔNG `late` / `late final`** — bắt buộc nullable + check null mỗi lần đọc:
  ```dart
  // ❌ KHÔNG
  late AnimationController _pulseController;
  // ✅ ĐÚNG
  AnimationController? _pulseController;
  // Khi dùng:
  final c = _pulseController;
  if (c == null) return const SizedBox.shrink();
  return ScaleTransition(scale: Tween(1.0, 1.05).animate(c), ...);
  ```
- **KHÔNG `setState`** — bắt buộc `ValueNotifier<T>` + `ValueListenableBuilder` (hoặc GetX `Rx<T>` + `Obx`). Ví dụ countdown:
  ```dart
  // ❌ KHÔNG
  setState(() => _remaining = newDuration);
  // ✅ ĐÚNG
  final ValueNotifier<Duration> _remaining = ValueNotifier(Duration.zero);
  // ...
  _remaining.value = newDuration;     // không trigger setState
  // Build:
  ValueListenableBuilder<Duration>(
    valueListenable: _remaining,
    builder: (_, d, __) => Text(_format(d)),
  )
  ```
- **KHÔNG `!` (bang operator)**:
  ```dart
  // ❌ KHÔNG
  AdManager().vip!.redeemVip(...);
  _pulseController!.repeat();
  // ✅ ĐÚNG (pattern matching Dart 3)
  if (AdManager().vip case final vip?) {
    vip.redeemVip(...);
  }
  // hoặc local copy
  final vip = AdManager().vip;
  if (vip == null) return;
  vip.redeemVip(...);
  ```
- **KHÔNG `Future.delayed` cho countdown** — bắt buộc `Timer.periodic`, `cancel()` trong `dispose`.
- **KHÔNG giữ rewarded callback dạng anonymous closure capture `this`** mà screen có thể `dispose()` trước khi callback fire — check `if (!mounted) return;` đầu callback.
- **KHÔNG quên `controller.dispose()`** cho từng `AnimationController`, `TextEditingController`, `FocusNode`, `Timer`, `StreamSubscription`, `ValueNotifier`, `ConfettiController` trong `dispose()`. Pattern:
  ```dart
  @override
  void dispose() {
    _keyController.dispose();
    _keyFocus.dispose();
    _shimmerController?.dispose();
    _entryController?.dispose();
    _pulseController?.dispose();
    _confettiController?.dispose();
    _tickTimer?.cancel();
    _activeSubscription?.cancel();
    _isProcessing.dispose();
    _entriesNotifier.dispose();
    _remaining.dispose();
    super.dispose();
  }
  ```

### 10.6 — VIP key whitelist + special entries

`vip_keys.dart`:

```dart
// Plaintext map (đơn giản):
final Map<String, Duration> kVipKeyMap = {
  'LOITP_30': const Duration(days: 30),
  'LOITP_3':  const Duration(days: 3),
};

// HOẶC Base64-obfuscated map (mức che giấu cao hơn — `_FlutterBase2025` đang làm):
// import 'dart:convert';
// final Map<String, Duration> kVipKeyMap = {
//   utf8.decode(base64Decode('OUZBMFE3RU4hMjdDTFgwNEAyMTk5M1kyVTBJNyNRMA==')):
//       const Duration(days: 30),
// };

Future<bool> vipKeyValidator(String normalisedKey) async =>
    kVipKeyMap.containsKey(normalisedKey);

Duration? lookupVipKeyDuration(String normalisedKey) =>
    kVipKeyMap[normalisedKey];
```

`VipManager.normaliseKey` (trim + uppercase) chạy trước validator → user gõ `loitp_30` hoặc ` LOITP_30 ` đều match.

**Special entries** (auto-managed bởi SDK, KHÔNG xoá thủ công):

| Key prefix | Source | UI label (i18n key) |
|---|---|---|
| `__FIRST_INSTALL__` | `firstInstallVipGrace.auto` (Step 9) | `'vip_entry_first_install'.tr` ('Quà tặng cài đặt mới') |
| `LEGACY_<gaid>` | Auto-migrated từ `vipDeviceGaids` (nếu set) | `'vip_entry_legacy'.tr` ('Thiết bị QA') |
| Khác | User redeem hoặc programmatic `addVip` | `entry.key` raw |

### 10.7 — Translations (mandate vi + en — Q26)

Thêm vào `lib/translations/vi_vn.dart` và `en_us.dart` (key snake_case):

```dart
// VIP
'vip_active', 'vip_free_user', 'vip_until',
'vip_activated_at', 'vip_expires_at', 'vip_remaining',
'vip_redeem_label', 'vip_redeem_hint', 'vip_redeem_button',
'vip_watch_ad_3d', 'vip_buy_30d_locked', 'vip_buy_90d_locked',
'vip_buy_1y_locked', 'vip_buy_lifetime_locked', 'vip_restore_locked',
'vip_revoke_all_button', 'vip_revoke_all_confirm_title',
'vip_revoke_all_confirm_message', 'vip_entry_first_install',
'vip_entry_legacy', 'vip_verifying_title', 'vip_success_title',
'vip_failed_title',

// Consent
'consent_title', 'consent_message', 'consent_allow', 'consent_reject',
'consent_privacy_label',

// Splash
'splash_ads_notice',

// Common
'privacy_policy', 'cancel', 'confirm', 'ok',
```

Các ngôn ngữ khác (zh / ja / ko / es / fr...) sẽ bổ sung ở SDK version sau — không add ở project này.

### 10.8 — Entry point từ AppBar

```dart
// Trong main screen (StressorHomePage / HomeScreen):
final vip = AdManager().vip;     // null-safe, không `!`
ValueListenableBuilder<bool>(
  valueListenable: vip?.activeListenable ?? ValueNotifier(false),
  builder: (_, active, __) => IconButton(
    icon: Icon(
      Icons.workspace_premium,
      color: active ? const Color(0xFFFFD60A) : Colors.white,
    ),
    onPressed: () => Get.to(() => const VipScreen()),
  ),
)
```

## Step 11 — Self-review & cập nhật `<PROJECT_PATH>/doc/AD.MD`

Review duy nhất 1 lần, KHÔNG lặp 3 lần. Checklist:

### 11.1 — Native config

- [ ] `pubspec.yaml`: `applovin_admob_sdk: <LATEST_STABLE>` + `gma_mediation_applovin:` (app-level) + 7 packages bắt buộc (Q37 → C):
  - `get`, `intl`, `url_launcher`, `confetti`, `app_tracking_transparency` (chỉ iOS), `shared_preferences` (đã có nếu dùng GetX), SDK
  - **Skip** `vibration` — dùng Flutter built-in `HapticFeedback.heavyImpact()`
- [ ] `AndroidManifest.xml` whitelist permissions (Q12B): `INTERNET` + `ACCESS_NETWORK_STATE` + `AD_ID`. Permission liên quan ad ngoài 3 cái này → có lý do rõ ràng. Permission ngoài ad → đã hỏi user.
- [ ] `AndroidManifest.xml` có AdMob `APPLICATION_ID` meta-data (production hoặc test ID + warning Q6C)
- [ ] `MainActivity` **KHÔNG** có `android:taskAffinity=""` (pitfall #1)
- [ ] (Nếu iOS) `ios/Runner/Info.plist` có `GADApplicationIdentifier`, `AppLovinSdkKey`, `NSUserTrackingUsageDescription`, `SKAdNetworkItems` (~70 entries)
- [ ] (Nếu iOS) Podfile target ≥ 13.0

### 11.2 — Bootstrap

- [ ] `main.dart`: `AdManager().setNavigatorKey` trước `runApp`, navigator observers đầy đủ (`adRouteObserver` + `AdScreenRouteLogger()`)
- [ ] (Nếu iOS) ATT prompt gọi trước `AdManager().initialize`
- [ ] Splash: `SimpleEventBus().listen` đăng ký TRƯỚC `initialize`, hard-cap (default 8s — Q24D), `markSplashActive/Inactive` đúng cặp, **hot-restart guard `countInitSplashScreen > 1`** (mandate — Q35A), App Open flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` đúng thứ tự
- [ ] Splash UI có disclaimer `'splash_ads_notice'.tr` (Q27A)
- [ ] `AdConfig.onLog` wire vào `SafeLogger` (Q9)

### 11.3 — Slot integration

- [ ] Mọi screen có ad đều extend `AdScreen` + `AdScreenState`
- [ ] Banner wrap edge-to-edge nếu app có `UIUtils.initEdgeToEdge()` (Q23D)
- [ ] Mọi slot ad đã thay (grep tên SDK cũ không còn match)
- [ ] Đã xoá deps SDK cũ trong `pubspec.yaml` (trừ `gma_mediation_applovin`)
- [ ] 2 build target ở Section 0 đều xanh (debug + release)
- [ ] `flutter analyze --fatal-infos` 0 issue

### 11.4 — VIP + Consent

- [ ] First-install VIP grace dùng SDK `auto`, KHÔNG override (Q34A)
- [ ] `AdKey` class ở `lib/<DART_PACKAGE_NAME>/common/const/ad_keys.dart` chứa `appLovin: AppLovinConfig(...)`, `adMob: AdMobConfig(...)`, `privacyPolicyUrl` (Q21A + Q29c)
- [ ] VIP screen có **đủ 13 thành phần UI** (10.3) + **đủ 5 animation** (10.4) + **0 vi phạm memory leak rule** (10.5)
- [ ] Translations vi + en đã thêm (10.7), 0 hard-code string user-facing (Q26)
- [ ] AppBar icon VIP reactive theo `vip?.activeListenable` (10.8)
- [ ] Consent: cả 3 wired (auto-show + UMP + iOS ATT)

### 11.5 — Code style enforcement (rule cốt lõi — Q3A + Q4D + Q28B)

- [ ] `grep -rn 'setState' lib/` → 0 match (trừ `super.setState` trong `BaseStatefulState` framework code, nếu có)
- [ ] `grep -rn '\!' lib/` review thủ công → 0 bang operator user-introduced (Dart syntax `!` cho `not equal !=` được phép, các pattern `expr!` khác cấm)
- [ ] `grep -rn 'late ' lib/` → 0 match
- [ ] `grep -rn 'late final' lib/` → 0 match

### 11.6 — Smoke test 5 bước (mandate Q31)

Chạy 1 lần trên emulator hoặc device thật (debug build), record kết quả từng bước:

```
1. Cold start app trên emulator/device (debug build).
   Verify: console không có "FATAL", "Exception", splash render trong < 1s.

2. Đợi splash flow.
   Verify: console log `🚀 AdManager singleton CREATED` xuất hiện đúng 1 lần.
   Verify: log `splash_ads_notice` text show.
   Verify: nếu network OK + ad load thành công → App Open Ad show, dismiss → vào main screen.
   Verify: nếu hard-cap (8s) trigger → main screen show ngay, không stuck.

3. Tap icon VIP 👑 ở AppBar → vào VipScreen.
   Verify: countdown text update mỗi giây (qua ValueNotifier, không setState).
   Verify: nếu first-install grace active → entry __FIRST_INSTALL__ hiện trong list với label `vip_entry_first_install`.tr.

4. Nhập key VIP hợp lệ (vd "LOITP_30") → tap "Kích hoạt".
   Verify: Cupertino "Verifying" dialog show ≥ 400ms.
   Verify: Success dialog show, list entry mới thêm vào.
   Verify: AppBar icon VIP đổi màu vàng `0xFFFFD60A` ngay lập tức (reactive ValueListenableBuilder).
   Verify: Hero card chuyển từ xám → gradient gold + crown shimmer animation chạy.
   Verify: confetti animation trigger + heavy haptic feedback.

5. Tap "Thu hồi tất cả VIP" → confirm trong Material 3 dialog.
   Verify: list entries empty.
   Verify: AppBar icon VIP đổi về outline trắng ngay lập tức.
```

Nếu có item FAIL → fix → check lại item đó (không re-check item đã PASS).

## Step 12 — Báo cáo cuối (1 lần, ≤ 25 dòng)

Format cố định, **chỉ 2 section**:

```
### Integration Result
- Build: flutter analyze=<PASS|FAIL>, flutter build apk --debug=<PASS|FAIL>, flutter build apk --release=<PASS|FAIL>, (iOS) flutter build ios --debug=<PASS|FAIL>
- Slots integrated: <N/M>
- Policy: <5/5 hoặc list rule fail>
- Memory review: <OK | list điểm nghi ngờ với file:line>
- VIP UI: <13/13 components, 5/5 animations | list missing>
- Code style: setState=<0 match>, !=<count user-introduced>, late=<0 match>, late final=<0 match>
- Smoke test: <5/5 PASS | step <X> FAIL: <reason>>
- Translations: vi=<count keys>, en=<count keys>
- Files changed: <count>, lines +<X> -<Y>
- AdMob APPLICATION_ID: <production | test ID — user not have AdMob account>

### Open questions for user
- <key/id còn thiếu cụ thể>
- <decision pending nếu có>
```

KHÔNG lặp lại "3 round". Step 11 checklist PASS hết → dừng. Có FAIL thì fix tới khi PASS rồi mới báo cáo.

---

## Phụ lục A — Cheat sheet API mapping (Android Kotlin → Flutter Dart)

Nếu user migrate từ project Android native dùng `_AdmobWrapper`, mapping nhanh:

| Android (Kotlin) | Flutter (Dart) |
|---|---|
| `AdManager.setConfig(...)` | `AdManager().initialize(config: AdConfig(...))` |
| `AdManager.requestConsentInfoUpdate(...)` | `AdManager().requestUmpConsent(...)` |
| `AdManager.awaitSplashComplete()` | `SimpleEventBus().listen` + `loadAppOpenAd` + `showAppOpenAd(bypassSafety: true)` |
| `AdManager.loadBanner(view, R.id.banner_container)` | `class _XxxState extends AdScreenState<Xxx>` → `buildBanner()` trong `build()` |
| `AdManager.showInterstitial { ... }` | `showInterstitialAd(onDone: (shown) {...})` |
| `AdManager.loadRewarded` + `showRewarded` | `showRewardedAd(onEarnedReward: (earned) {...})` |
| `AdManager.activateVipByKey(base64)` | `AdManager().vip` (null-safe) → `redeemVip(context, key:, duration:, validator:, strings:)` |
| `AdSafetyLimits(interstitialMinIntervalSec: 60, ...)` | `AdSafetyParams.production.copyWith(...)` (mặc định `auto`, KHÔNG override) |
| `BuildConfig.IS_ENABLE_ADMOB` flag | Đổi `AdConfig.provider` (`AdProvider.appLovin` ↔ `AdProvider.adMob`) |
| `Application.onCreate { AdManager.initialize() }` | `main()` chỉ `setNavigatorKey`, init trong `SplashScreen.initState()` |
| `ProcessLifecycleOwner` cho App Open resume | SDK auto qua `WidgetsBindingObserver` — KHÔNG tự subscribe |
| Fragment + `onDestroyView` | `StatefulWidget` + `dispose()` |
| `ObjectAnimator`, `ValueAnimator`, `CountDownTimer` | `AnimationController`, `TweenAnimationBuilder`, `Timer.periodic` |
| `SharedPreferences.edit().putBoolean(...)` | `package:shared_preferences` `prefs.setBool(...)` |
| `DateFormat.getDateInstance(MEDIUM)` | `package:intl` `DateFormat('dd/MM/yyyy')` |
| `VibrationEffect.EFFECT_CLICK` | `HapticFeedback.heavyImpact()` (Flutter built-in) |
| Material You (`com.google.android.material`) | Material 3 (`ThemeData(useMaterial3: true)`) |
| Kotlin `lateinit var` | **CẤM** `late` — dùng nullable + check (Step 10.5) |
| Kotlin `!!` | **CẤM** `!` — dùng pattern matching `if (x case final v?)` hoặc local copy |
| `viewModel.observe { setState }` | `ValueListenableBuilder` + `ValueNotifier` (hoặc GetX `Obx` + `Rx<T>`) — **KHÔNG `setState`** |

## Phụ lục B — Reference doc của project `_FlutterBase2025`

Project này là reference implementation cho `applovin_admob_sdk: ^1.0.18`. Files đáng đọc:

- `doc/AD.MD` — audit + as-is spec đầy đủ (touchpoint table, ad config, UMP flow, VIP system, policy compliance)
- `lib/main.dart` — bootstrap pattern
- `lib/mckimquyen/widget/splash/splash_screen.dart` — splash flow chuẩn (UMP + initialize + App Open + hard cap 8s + hot-restart guard)
- `lib/mckimquyen/widget/wifi_stressor/wifi_stressor_screen.dart` — example screen extend `AdScreen` + buildBanner + showInterstitialAd + VIP icon
- `lib/mckimquyen/widget/wifi_stressor/presentation/history_screen.dart` — example showRewardedAd
- `lib/mckimquyen/widget/vip/vip_screen.dart` — VIP UI reference (13 components — sẽ bổ sung row 13 "Restore Purchase" theo Q33A)
- `lib/mckimquyen/widget/vip/vip_keys.dart` — Base64-obfuscated key map pattern
- `lib/translations/vi_vn.dart` + `en_us.dart` — i18n keys
- `packages/ad_sdk/README.md` — full SDK API reference
