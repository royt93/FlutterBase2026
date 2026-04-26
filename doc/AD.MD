# 📊 TÍCH HỢP QUẢNG CÁO — `applovin_admob_sdk` v1.0.16

> **Phạm vi:** audit + đặc tả as-is của repo `_FlutterBase2025` sau khi migrate từ
> v1.0.14 → v1.0.16. File này phản ánh state thực tế của code (file:line cụ thể),
> không phải template chung. Khi sửa code, cập nhật mục tương ứng ở đây trước.
>
> **Provider hiện tại:** `AdProvider.appLovin` (nhúng AdMob qua mediation).
>
> **Ad units (production AppLovin MAX):** xem `lib/mckimquyen/widget/splash/splash_screen.dart:124–129`.

---

## 1. TỔNG QUAN VERSION

| | Giá trị |
|---|---|
| SDK package | `applovin_admob_sdk` v1.0.16 (`pubspec.yaml:46`) |
| Native mediation | `gma_mediation_applovin` (app-level, `pubspec.yaml:52`) |
| iOS deployment target | 13.0 (`ios/Podfile`) |
| Android `minSdk` / `targetSdk` / `compileSdk` | 24 / 36 / 36 |
| AdMob `APPLICATION_ID` | `ca-app-pub-3612191981543807~9731053733` (`AndroidManifest.xml:53`) |
| Provider package native | AppLovin MAX SDK key bundled in code (Dart) |

### v1.0.16 highlights đã apply trong repo

- ✅ Documentation-only release từ 1.0.15. Không có breaking change runtime.
- ✅ Manifest pitfall đã clean: `MainActivity` **KHÔNG** set `android:taskAffinity=""` (`AndroidManifest.xml:58–65`). Đây là pitfall #1 của 1.0.15 — nếu set rỗng, AppLovin fullscreen activity sẽ "rơi" sang task khác và user bị đẩy về launcher khi quay lại app.

### v1.0.15 features đã wired

| Feature | Wired? | File:line |
|---|---|---|
| Smart App-Open timeout (5s polling, 90s hard cap) | ✅ tự động (no-op) | (SDK internal) |
| Slot-state dismiss watcher | ✅ tự động (no-op) | (SDK internal) |
| `requestUmpConsent()` (UMP wrapper) | ✅ | `splash_screen.dart:120–128` |
| `ConsentDialogStrings` từ translations | ✅ | `splash_screen.dart:166–173` |
| `ConsentDialog` privacy URL | ✅ | `splash_screen.dart:172` |
| `firstInstallVipGrace: auto` (30s debug / 24h release) | ✅ default, không override | `splash_screen.dart` (config) |
| `vipKeyValidator` + `kVipKeyMap` | ✅ | `widget/vip/vip_keys.dart`, `splash_screen.dart:178` |
| `VipDialogStrings` từ translations | ✅ | `splash_screen.dart:181–190` |
| `logLevel` build-mode-aware | ✅ | `splash_screen.dart:163` |
| `VipManager` UI (redeem / revoke / list) | ✅ | `widget/vip/vip_screen.dart` |

---

## 2. KIẾN TRÚC AD HIỆN TẠI

```
main()                                                  lib/main.dart:33
  └── AdManager().setNavigatorKey(navigatorKey)        :36   (PHẢI trước runApp)
  └── runApp(GetMaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [
          adRouteObserver,                              :81   (banner pause/resume)
          AdScreenRouteLogger(),                        :82   (route logging)
        ],
        home: MyApp() → SplashScreen,
      ))

SplashScreen                                           widget/splash/splash_screen.dart
  ├── markSplashActive() / incrementSplashCount()      :40–42
  ├── HARD CAP 8s timer                                :55–58
  ├── SimpleEventBus.listen(_eventListener)            :107  (đăng ký TRƯỚC initialize)
  ├── (optional) AdManager().requestUmpConsent()       :120–128  ← v1.0.15 NEW
  ├── AdManager().initialize(config: AdConfig(...))    :131–198  ← v1.0.15 features
  └── EventBus(true) → loadAppOpenAd → buffer → showAppOpenAd(bypassSafety: true)

StressorHomePage extends AdScreen                      widget/wifi_stressor/wifi_stressor_screen.dart
  ├── buildBanner()                                    :115
  ├── showInterstitialAd() khi navigate History/start/stop test :164,298
  └── _buildVipAction() → push VipScreen               :157–183 ← NEW

HistoryScreen extends AdScreen                         widget/wifi_stressor/presentation/history_screen.dart
  ├── buildBanner()                                    :87
  └── showRewardedAd() khi clear history               :50

VipScreen extends StatefulWidget                       widget/vip/vip_screen.dart  ← NEW
  ├── ValueListenableBuilder<bool>(vip.activeListenable) → hero card
  ├── ValueListenableBuilder<List<VipEntry>> → entries list
  ├── vip.redeemVip(context, key, duration, validator, strings) → SDK Cupertino flow
  └── vip.revokeVip(key) / vip.revokeAll()
```

---

## 3. AD UNITS (PRODUCTION)

> Provider: `AdProvider.appLovin`. Source: `splash_screen.dart:124–129`.

| Loại | AppLovin Ad Unit ID |
|---|---|
| SDK Key | `REDACTED_APPLOVIN_SDK_KEY_ROUND68` |
| Banner | `REDACTED_APPLOVIN_BANNER_ID` |
| Interstitial | `REDACTED_APPLOVIN_INTERSTITIAL_ID` |
| App Open | `REDACTED_APPLOVIN_APPOPEN_ID` |
| Rewarded | `REDACTED_APPLOVIN_REWARDED_ID` |

> ⚠️ Đây là production IDs. Để test impressions không bị đếm, dùng AppLovin Mediation Debugger (3-finger long-press trong app) hoặc đăng ký GAID thiết bị qua test mode trong AppLovin Dashboard.

---

## 4. AD CONFIG ĐẦY ĐỦ HIỆN TẠI

> Source: `lib/mckimquyen/widget/splash/splash_screen.dart` (block `AdManager().initialize`).

```dart
AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(sdkKey, bannerId, interstitialId, appOpenId, rewardedId),

  // ─ User-facing strings ────────────────────────────────────
  adNotReadyMessage: 'ad_not_ready'.tr,
  adLoadingMessage: 'loading'.tr,

  // ─ Logging (Q5) ───────────────────────────────────────────
  logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,

  // ─ Consent dialog (Q1A + Q9B) ─────────────────────────────
  // Auto-show ~1s sau markSplashInactive (default true). Strings từ
  // translations vi/en. Privacy URL = Notion page.
  consentDialogStrings: ConsentDialogStrings(
    title: 'consent_title'.tr,
    message: 'consent_message'.tr,
    allowButton: 'consent_allow'.tr,
    rejectButton: 'consent_reject'.tr,
    privacyPolicyLabel: 'consent_privacy_label'.tr,
    privacyPolicyUrl: 'https://loitp.notion.site/Term-...',
  ),

  // ─ VIP redeem (Q14, Q15) ──────────────────────────────────
  vipKeyValidator: vipKeyValidator,        // kiểm tra key vs kVipKeyMap
  vipDialogStrings: VipDialogStrings(...), // từ translations vi/en

  // ─ Legacy GAID list (Q16B: keep) ──────────────────────────
  // SDK auto-migrates → VipManager entries (year-2099) cho device khớp GAID.
  vipDeviceGaids: const [/* 21 GAIDs QA devices */],

  // ─ Defaults không override ────────────────────────────────
  // firstInstallVipGrace: auto    (30s debug / 24h release)  ← Q2B
  // autoShowConsentDialog: true   (auto-show post-splash)
  // safety: AdSafetyParams.auto   (12-layer guard, không tinh chỉnh)
  // splashMaxDuration: 8s         (đồng bộ với hard-cap timer)
  // loadingBufferMs: 1000         (buffer trước fullscreen ad)
)
```

---

## 5. UMP CONSENT FLOW (v1.0.15 NEW)

> Source: `splash_screen.dart:120–128`.

```dart
try {
  final umpResult = await AdManager().requestUmpConsent(testMode: false);
  // → Map UMP → AdConsent → setConsent(...) (SDK auto)
} catch (e) {
  SafeLogger.w('Splash', 'UMP threw, continuing init anyway: $e');
}
// → init bình thường dù canRequestAds == false (Q11A: fallback non-personalized)
AdManager().initialize(config: ...);
```

**Hành vi:**
- **Non-EEA user:** `requestConsentInfoUpdate` trả `notRequired` ngay → form không show → `canRequestAds=true`. Không có thêm UI.
- **EEA user, lần đầu:** `notRequired` → `required` → `ConsentForm` Google show → user chọn → cập nhật status. Splash hard-cap 8s vẫn chạy → nếu user đọc form quá lâu, navigate về home, lần sau mở app vào lại splash với cached consent.
- **Không có internet:** `requestConsentInfoUpdate` fail → catch và continue. SDK vẫn init, ads sẽ load lại khi có internet.
- **iOS ATT:** UMP flow này KHÔNG show ATT prompt. App chưa wire `app_tracking_transparency` package — nếu cần, thêm sau riêng.

---

## 6. CONSENT DIALOG (Cupertino, Auto-show)

`autoShowConsentDialog: true` (default). SDK schedule `Timer(consentDialogPostSplashDelay = 1s)` ngay khi `markSplashInactive` → trên home screen show binary dialog "Allow / Reject".

**Skip điều kiện:**
- VIP đang active → skip (đỡ làm phiền user trả phí). Vì `firstInstallVipGrace: auto` mặc định 24h release → user fresh-install **sẽ KHÔNG thấy dialog trong 24h đầu**, dialog chỉ surface sau khi grace expire.
- `hasBeenAsked == true` → skip vĩnh viễn (lưu SharedPreferences).
- Không có `navigatorKey` → skip (logged warning).

**Manual re-show** (vd Privacy settings page): `ConsentManager.instance.showDialog(context, strings: ..., barrierDismissible: ...)`.

---

## 7. VIP SYSTEM

### 7.1 Key whitelist

> Source: `lib/mckimquyen/widget/vip/vip_keys.dart`.

```dart
const Map<String, Duration> kVipKeyMap = {
  'LOITP_30': Duration(days: 30),
};

Future<bool> vipKeyValidator(String normalisedKey) async {
  return kVipKeyMap.containsKey(normalisedKey);
}
```

- `VipManager.normaliseKey` (trim + uppercase) chạy trước khi gọi validator → user gõ `loitp_30` hoặc ` LOITP_30 ` đều match.
- Thêm key mới: thêm 1 entry vào `kVipKeyMap`. Không cần đổi UI.

### 7.2 VipScreen (entry point)

`StressorHomePage` AppBar → icon 👑 (`Icons.workspace_premium`) → `Get.to(VipScreen())`.

Icon đổi màu reactive theo `vip.activeListenable`:
- `false` → outline trắng
- `true` → filled vàng `0xFFFFD60A`

### 7.3 VipScreen sections

| Section | Source | Behaviour |
|---|---|---|
| Hero card | `_buildHeroCard` | Gradient gold (active) / xám (inactive). Crown icon có shimmer ring khi active. Hiển thị "Hiệu lực đến @date" + remaining-badge. |
| Redeem section | `_buildRedeemSection` | TextField uppercase auto, prefix icon ticket, suffix clear. Button "Kích hoạt" gradient gold + spinner khi processing. |
| Active entries | `_buildEntriesSection` | List card mỗi entry (FIRST_INSTALL / LEGACY_xxx / user key) với icon riêng, days/hours remaining, expires date, revoke button. Header có "Thu hồi tất cả" nếu nhiều entry. |
| Footer | `_buildFooter` | Privacy Policy link → `url_launcher` external browser. |

### 7.4 Redeem flow (sequence)

```
User nhập key → tap "Kích hoạt"
  → FocusScope.unfocus()                          (đóng keyboard)
  → _isProcessing.value = true                    (button → spinner)
  → vip.redeemVip(context, key, duration, validator, strings)
    → SDK show Cupertino "Verifying" dialog
    → await validator(normalisedKey)              (≥400ms artificial delay nếu null)
    → SDK pop verifying
    → ok? addVip(key, duration) → show success    (return true)
    → !ok? show failed                            (return false)
  → finally: _isProcessing.value = false
  → ok? clear input + heavy haptic + refresh entries
```

### 7.5 Special entries

| Key prefix | Source | UI |
|---|---|---|
| `__FIRST_INSTALL__` | `firstInstallVipGrace.auto` (SDK) | Icon 🎉, label "Quà tặng cài đặt mới" |
| `LEGACY_<gaid>` | Auto-migrated từ `vipDeviceGaids` (SDK) | Icon 📱, label "Thiết bị QA" |
| Khác | User redeem (vd `LOITP_30`) | Icon 🎟, label = key |

### 7.6 Reactivity

- `vip.activeListenable` → hero card + AppBar icon đổi màu.
- `vip.activeStream` → re-fetch entries khi active state đổi (cover case external add).
- Local `Timer.periodic(30s)` → re-render remaining-time text mượt (không poll API, chỉ rebuild UI từ entries hiện có).

---

## 8. TOUCHPOINTS — TỔNG HỢP

| Loại ad | Touch point | File:line | Note |
|---|---|---|---|
| App Open (cold) | Splash sau init + load + buffer | `splash_screen.dart:79–110` | `bypassSafety: true` |
| App Open (resume) | SDK auto qua `WidgetsBindingObserver` | (SDK internal) | Yêu cầu `setNavigatorKey` ở `main.dart:36` |
| Banner | Stressor home top | `wifi_stressor_screen.dart:115` | `buildBanner()` từ AdScreen |
| Banner | History screen top | `presentation/history_screen.dart:87` | `buildBanner()` từ AdScreen |
| Interstitial | Tap "Start test" | `wifi_stressor_screen.dart:164` | `showInterstitialAd(onDone:)` |
| Interstitial | Tap "Stop test" | `wifi_stressor_screen.dart:298` | `showInterstitialAd(onDone:)` |
| Interstitial | Navigate to History | `wifi_stressor_screen.dart:164` | `showInterstitialAd(onDone:)` |
| Rewarded | Clear history button | `presentation/history_screen.dart:50` | `showRewardedAd(onEarnedReward:)` |
| VIP nav | AppBar icon 👑 | `wifi_stressor_screen.dart:181` | KHÔNG show inter (UX VIP phải mượt) |

---

## 9. POLICY COMPLIANCE AUDIT

### 9.1 AdMob policy (qua mediation)

| Rule | Status | Note |
|---|---|---|
| Không show interstitial trên splash | ✅ Splash dùng App Open Ad, không Interstitial | App Open tách biệt slot, được phép trên splash |
| App Open `bypassSafety` chỉ 1 lần ở splash | ✅ | Resume App Open vẫn check `canShowAppOpenOnResume()` (4 guards) |
| Không show ad chồng nhau | ✅ | SDK có `_isInterstitialShowing` + `_lastFullscreenDismissTime` 2s cooldown + slot-state watcher v1.0.15 |
| Không gây hiểu nhầm "tap để xem nội dung" rồi show ad | ✅ | Mỗi touch point đều có UX rõ ràng (button có label) |
| AdMob `APPLICATION_ID` trong AndroidManifest | ✅ | Line 51–53 |
| AndroidManifest permissions | ✅ | `AD_ID`, `INTERNET`, `ACCESS_NETWORK_STATE` (line 5–11) |
| iOS `GADApplicationIdentifier` / `SKAdNetworkItems` / `NSUserTrackingUsageDescription` | ⚠️ | Cần verify `ios/Runner/Info.plist` có đầy đủ 4 keys (out of scope migration này) |

### 9.2 AppLovin policy

| Rule | Status | Note |
|---|---|---|
| SDK key truyền qua code, không trong manifest | ✅ | `splash_screen.dart:124` |
| Mediation Debugger có thể truy cập | ✅ | AppLovin tự bật trong debug builds |
| `taskAffinity` không rỗng | ✅ | `AndroidManifest.xml:58–65` không có attribute → default = package name |
| `gma_mediation_applovin` ở app-level | ✅ | `pubspec.yaml:52` (KHÔNG ở sub-package) |

### 9.3 GDPR / EEA

| Rule | Status | Note |
|---|---|---|
| UMP form show TRƯỚC first ad request | ✅ | `splash_screen.dart:120–128` chạy trước `initialize()` |
| Non-personalized fallback nếu reject | ✅ | SDK `setConsent` map `canRequestAds=false` → AdConsent.hasUserConsent=false |
| Privacy Policy URL | ✅ | Nhúng vào `ConsentDialogStrings.privacyPolicyUrl` |

### 9.4 Safety guards (12 layers, SDK tự động)

> Không tinh chỉnh trong app — `AdSafetyParams.auto` đủ.

App Open + Inter + Rewarded: throttle 60s, session cap 6, hourly cap 3, daily cap 5, suspicious CTR 30%, click spam 3/min, cold start skip, rapid resume 3/min, loading dialog 1s, mutex chống double-load, `_isInterstitialShowing` chống AppOpen, `_lastFullscreenDismissTime` 2s cooldown.

Banner: navigation cooldown 5s, click spam 3/min.

---

## 10. SO SÁNH TRƯỚC / SAU MIGRATE v1.0.14 → v1.0.16

| Hạng mục | Trước (v1.0.14) | Sau (v1.0.16) |
|---|---|---|
| Pubspec version | `^1.0.14` (legacy doc nói thế) | `^1.0.16` |
| Consent dialog | ❌ Không có | ✅ Cupertino auto-show, vi/en strings từ translations |
| UMP wrapper | ❌ Không gọi | ✅ `requestUmpConsent` chạy trước `initialize` |
| First-install VIP grace | ❌ Không có | ✅ `auto` (24h release / 30s debug) |
| VIP redeem UI | ❌ Không có | ✅ `VipScreen` riêng + Cupertino verifying/success/failed dialogs |
| VIP key validator | ❌ Không có | ✅ `kVipKeyMap` whitelist, `LOITP_30 → 30 ngày` |
| AppOpen timeout | Fixed 10s (false-positive khi user click ad → browser) | Lifecycle-aware polling 5s tick / 90s cap |
| Slot dismiss watcher | ❌ Bug: rewarded `onDone` fire khi earn-reward, không phải dismiss → AppOpen show ngay sau rewarded | ✅ Fix bằng slot-state transition watcher |
| Banner paid-event | ❌ Silently fail (dynamic dispatch) | ✅ `BannerAdListener.onPaidEvent` |
| Log level | Verbose mặc định | `kDebugMode ? verbose : warning` |
| `taskAffinity=""` pitfall | Tiềm ẩn | ✅ Verified clean (`AndroidManifest.xml:58`) |
| Hot-restart `markSplashInactive` | ⚠️ Chỉ gọi sau 1 frame | ✅ Sync ngay khi detect `count > 1` |
| Comment "300ms buffer" | ❌ Sai (default thực tế 1000ms) | ✅ Comment chính xác |

---

## 11. CHECKLIST RELEASE

- [ ] Production AppLovin/AdMob IDs đã đúng (không phải test ID).
- [x] `AndroidManifest.xml` có `APPLICATION_ID`, `AD_ID`, `INTERNET`, `ACCESS_NETWORK_STATE`.
- [x] `MainActivity` KHÔNG có `android:taskAffinity=""`.
- [ ] `ios/Runner/Info.plist` có `GADApplicationIdentifier`, `SKAdNetworkItems`, `NSUserTrackingUsageDescription`, `AppLovinSdkKey`.
- [ ] iOS Podfile target ≥ 13.0, đã `pod install`.
- [x] Privacy Policy URL valid và load được external browser.
- [x] `firstInstallVipGrace` strategy aligned (auto = ad-free 24h release).
- [x] VIP key `LOITP_30` test redeem thành công, đếm còn 30 ngày.
- [ ] Test thật trên thiết bị (emulator không show real ad).
- [ ] Mediation Debugger không có "no-fill 100%" trên unit production.

---

## 12. TROUBLESHOOTING

### Splash bị treo > 8s
Check log `[Splash]` — UMP có thể đang block. Hard cap 8s sẽ tự navigate. Lần mở sau cached UMP nên fast.

### Consent dialog không hiện
1. VIP đang active (kiểm tra `vip.isActive`) → expected, dialog skip cho VIP.
2. `hasBeenAsked == true` (đã chọn rồi) → expected, không re-prompt.
3. `setNavigatorKey` chưa gọi → check `main.dart:36`.

### VIP key đúng nhưng "Mã không hợp lệ"
1. Check `kVipKeyMap` có key đó không (case insensitive — SDK normalise).
2. Verify `vipKeyValidator` truyền vào `AdConfig.vipKeyValidator` (`splash_screen.dart:178`).

### App Open Ad không show khi resume
1. Cold start skip — lần resume đầu tiên luôn skip.
2. Background < 5s — bị `canShowAppOpenOnResume` reject.
3. VIP active — expected, ads suppressed.
4. Daily cap reached → check log `🛡️ Daily limit`.

### Banner không hiển thị
1. VIP active → expected, banner skipped.
2. Network sai → check log `[BannerAdWidget] _initBanner ⏭️`.
3. Cooldown sau lỗi load → đợi 5 phút.

---

## 13. PHIÊN BẢN

| Ngày | Version | Thay đổi |
|---|---|---|
| 20260321 | v1–v17 | Port từ Kotlin Native → Flutter, single-file `AdManager` |
| 20260322 | v18 | Tách ra package `applovin_admob_sdk`, 43 bug fixes |
| 20260323 | v19 | Fix #47: Loading dialog cho App Open resume |
| 20260324 | v20 | Fix #48: `_assertInitialized` không crash |
| 20260324 | v21 | Rewrite Integration Guide cho fresher |
| 20260423 | v22 (1.0.14) | Production-hardened baseline |
| 20260426 | **v23 (1.0.15)** | **+ConsentManager, +UMP wrapper, +firstInstallVipGrace, +slot dismiss watcher, +smart timeout, fix `taskAffinity` pitfall** |
| 20260426 | **v24 (1.0.16)** | **Documentation overhaul (no runtime change)** |
| 20260426 | **v25 (host)** | **Repo host adopts 1.0.15 features (consent strings vi/en, UMP, vipKeyValidator+LOITP_30, VipScreen, logLevel)** |
