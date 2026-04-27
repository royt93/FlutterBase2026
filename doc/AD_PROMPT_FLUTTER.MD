# Prompt Template: Migrate hệ thống Ad sang `_AdmobWrapper` (Android native)

> Template dùng chung cho mọi project Android native. Trước khi đưa cho AI, **fill hết placeholder `<...>`** ở Section 0. VIP feature là **mandatory**, mọi project đều phải apply (không có cơ chế skip).

---

## 0. Bối cảnh — fill trước khi chạy

| Field | Giá trị |
|---|---|
| Project hiện tại (cwd, absolute path) | `<PROJECT_PATH>` |
| Lib reference (absolute path) | `/Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_AdmobWrapper` |
| File spec gốc của lib | `/Users/loitran/AndroidStudioProjects/@mckimquyen/@playstore/@prodution/_AdmobWrapper/doc/AD.MD` |
| Lib coordinate + version | `com.github.royt93:AdmobApplovinWrapper:1.1.3` |
| Build variant phải xanh (debug) | `<assemble{Flavor}Debug>` |
| Build variant phải xanh (release) | `<assemble{Flavor}Release>` |
| Provider chính (active runtime) | `AppLovin MAX` |
| Provider fallback | `AdMob` (chỉ active khi `BuildConfig.IS_ENABLE_ADMOB=true`) |
| AppLovin SDK key | `REDACTED_APPLOVIN_SDK_KEY_ROUND68` |
| AppLovin banner ID | `<hỏi user — dừng nếu thiếu>` |
| AppLovin interstitial ID | `<hỏi user — dừng nếu thiếu>` |
| AppLovin app open ID | `<hỏi user — dừng nếu thiếu>` |
| AppLovin rewarded ID | `<hỏi user — dừng nếu thiếu>` |
| AdMob banner ID | `<hỏi user — dừng nếu thiếu>` |
| AdMob interstitial ID | `<hỏi user — dừng nếu thiếu>` |
| AdMob app open ID | `<hỏi user — dừng nếu thiếu>` |
| AdMob rewarded ID | `<hỏi user — dừng nếu thiếu>` |
| VIP key 30 ngày (plain) | `9fA0q7eN!27cLx04@21993Y2u0I7#Q0` |
| VIP key 3 ngày (plain) | `eQ7@93L0f!2Y2707xN04021993u0I#2aK` |
| Mức che giấu VIP key | Base64 hardcode (AI tự encode plain → Base64 khi compile vào code) |

**Rule cứng cho Section 0**:

1. **Cả 2 bộ ID (AppLovin + AdMob) đều phải đầy đủ** trước khi setup `AdSdkConfig`, dù chỉ AppLovin active runtime — vì khi flip `IS_ENABLE_ADMOB=true` không phải re-build template.
2. Bất kỳ field nào còn ghi `<hỏi user — dừng nếu thiếu>`: AI **phải hỏi user trong chat** rồi **dừng chờ trả lời**, KHÔNG tự fill placeholder, KHÔNG dùng test ID, KHÔNG bỏ qua.
3. AppLovin SDK key đã hardcode trong template này — chấp nhận do file PROMT.MD là internal. Khi compile vào project, key này phải đi qua `BuildConfig` (không hardcode trong source `.kt`).

---

## Cấm (áp dụng mọi project)

- Tự ý thêm ad slot mới ngoài các slot đã tồn tại trong code hiện tại.
- Tự ý refactor code không liên quan đến migrate ad.
- Tự ý nâng version lib hoặc đổi flag `IS_ENABLE_ADMOB`.
- Lặp lại đọc cùng 1 file > 1 lần với mục đích "double check" — review trên kết quả đã có, không re-read.
- Tự thêm trigger interstitial mới (vd "show sau mỗi action X") nếu code cũ chưa có.
- Tự fill ad ID bằng test ID hoặc placeholder — phải hỏi user.

---

## Step 1 — Đọc lib reference

- `ls` đệ quy `<LIB_PATH>` để nắm cấu trúc.
- Đọc `<LIB_PATH>/doc/AD.MD` (spec gốc) trước.
- Đọc sample app trong lib (`app/` hoặc `sample/`), đặc biệt các call site: `AdManager.setConfig`, `initialize`, `requestConsentInfoUpdate`, `awaitSplashComplete`, `loadBanner`, `showInterstitial`, `loadRewarded`, `showRewarded`, `activateVipByKey`, `AdSafetyLimits`.
- **`AdSafetyLimits` debug-friendly**: ở `BuildConfig.DEBUG=true`, dùng giá trị dễ dãi hơn để QC test nhanh. Giá trị đề xuất (verify field name chính xác từ lib ở step này, đổi tên field nếu lib dùng tên khác):

  | Field | Debug | Release |
  |---|---|---|
  | `interstitialMinIntervalSec` | `10` | `60` |
  | `appOpenMinIntervalSec` | `10` | `120` |
  | `interstitialMaxPerSession` | `999` | giữ default lib |
  | `appOpenMaxPerSession` | `999` | giữ default lib |

  Wire bằng `if (BuildConfig.DEBUG) AdSafetyLimits(...) else AdSafetyLimits()` trong `Application.onCreate`.

**Output bắt buộc**: 1 đoạn ≤ 10 dòng tóm tắt API surface của lib và lifecycle nó tự quản (App Open auto qua `ProcessLifecycleOwner`, banner auto pause/resume/destroy, frequency cap…).

## Step 2 — Audit hiện trạng project

Trả lời 5 câu (yes/no + dẫn chứng `file:line`):

1. Project đã apply `_AdmobWrapper` chưa? Hay vẫn còn SDK cũ (vd `AdMobManager`, `AdsHelper`, `MaxManager`…)?
2. `Application.onCreate` đang gọi gì để init ad?
3. Splash activity có gọi consent + App Open warmup chưa?
4. Activity nào đang load banner và interstitial bằng API nào (`AdView`, `InterstitialAd.load`, `MaxAdView`…)?
5. **Đã có VIP screen chưa?** Nếu có → AI sẽ **upgrade in-place** ở Step 10, KHÔNG tạo trùng. Nếu chưa → tạo mới. Mô tả UI hiện tại nếu có.

## Step 3 — Viết kế hoạch migrate vào `<PROJECT_PATH>/doc/AD.MD`

File đích: `<PROJECT_PATH>/doc/AD.MD` (tạo mới nếu chưa có).

Bắt buộc có các section:

**(1) Touchpoint table** — mỗi slot 1 dòng. Nếu slot chưa tồn tại trong project, ghi `(chưa có)` ở cột "API cũ thay thế":

| Slot | File hiện tại | Trigger | API mới | API cũ thay thế |
|---|---|---|---|---|
| Banner | `<host activity/fragment>` | `<onCreate / onViewCreated>` | `AdManager.loadBanner` | `<API cũ>` |
| Interstitial | `<host>` | `<trigger giữ nguyên>` | `AdManager.showInterstitial` | `<API cũ>` |
| App Open | Splash + foreground resume | warmup ở splash + `ProcessLifecycleOwner` cho resume | `AdManager.awaitSplashComplete` | `<API cũ hoặc (chưa có)>` |
| Rewarded | VIP screen, nút "Watch ad → 3 days VIP" | user click | `AdManager.loadRewarded` + `showRewarded`, fallback `showInterstitial` | `<API cũ hoặc (chưa có)>` |

**(2) Step-by-step migrate plan** — 6 bước (Setup, App Init + Consent, VIP UI, Banner, Interstitial, Rewarded). Mỗi bước nói rõ file edit, hàm thêm, dòng xoá.

**(3) Bảng so sánh trước/sau** — tối thiểu 8 dòng (Provider, Architecture, App Open, Consent, Memory leak risk, Frequency cap, VIP, Lifecycle).

**(4) Thông tin cần user cấp** — list rõ những gì còn thiếu: ad unit ID, test device ID, EEA test config, banner placement layout id…

## Step 4 — Lifecycle requirement (rule cứng, áp dụng mọi project)

- **App Open ở Splash**: gọi `requestConsentInfoUpdate` xong → `awaitSplashComplete` → mới navigate sang main. **KHÔNG** show App Open trên splash thuần (vi phạm AdMob policy "Disallowed interstitial implementations").
- **App Open khi quay lại foreground**: dùng cơ chế của lib (đã hook `ProcessLifecycleOwner`). KHÔNG tự subscribe `ON_START` lần thứ 2 trong project — tránh double-show.
- **Banner**: gắn vào layout container có sẵn (`<R.id.banner_container>` hoặc tương đương). KHÔNG gọi `pause()/resume()/destroy()` thủ công — lib tự lo.
- **Interstitial**: chỉ thay call site cũ, không thêm trigger mới. Tin tưởng `AdSafetyLimits` để chống click-tặc.
- **Rewarded**: chỉ load + show khi user bấm nút trong VIP screen.

## Step 5 — Phạm vi thay thế

Chỉ thay đúng các call site cũ. Trước khi xoá file/hàm SDK cũ, **grep verify** không còn ai dùng:

- Liệt kê file SDK cũ sẽ xoá (vd `AdMobManager.kt`, `AdsHelper.kt`…).
- Với mỗi file: grep tên class/hàm trong toàn project, xác nhận 0 reference, rồi mới xoá.
- Không tự thêm banner/interstitial/rewarded ở activity/fragment khác.

## Step 6 — Build & memory check (review chung toàn project)

- Chạy 2 build variant đã chốt ở Section 0 — cả 2 phải xanh.
- Memory leak: review thủ công 3 điểm (KHÔNG cần LeakCanary):
  - Activity host banner có giữ reference banner sau `onDestroy` không?
  - Fragment/Activity host rewarded có giữ reference callback không?
  - `Application` class có leak `Activity` qua `AdManager` callback không?
- Output: bảng "điểm review / kết luận / `file:line` dẫn chứng".

## Step 7 — Policy check (5 rule cụ thể, không hơn không kém)

| # | Rule | Cách verify |
|---|---|---|
| 1 | Banner không che nội dung tương tác | Đọc layout host banner, xác nhận banner ở dock bottom/top, không overlay nút bấm |
| 2 | App Open không show trên splash thuần — chỉ show khi warmup xong trước khi vào main, hoặc khi resume từ background | Đọc Splash activity + lifecycle hook |
| 3 | Interstitial không show liên tiếp dưới ngưỡng frequency cap | Tin `AdSafetyLimits` mặc định, ghi rõ giá trị dùng (debug vs release) |
| 4 | Rewarded chỉ trigger khi user bấm nút | Đọc VIP screen |
| 5 | Không tự click ad / không có UI giả mạo close button | Đọc layout banner |

Báo cáo: PASS/FAIL từng rule + `file:line` dẫn chứng.

## Step 8 — Consent (UMP)

- Gọi `AdManager.requestConsentInfoUpdate` ở Splash `onCreate`.
- Block load App Open + Banner + Interstitial cho tới khi consent resolved.
- Test scenario tối thiểu cần ghi nhận trong báo cáo (KHÔNG cần chạy thực):
  - Non-EEA: skip dialog, ad load bình thường.
  - EEA, user accept: dialog xong, ad load.
  - EEA, user deny: dialog xong, không load personalized ad (lib tự lo).

## Step 9 — VIP 1 ngày auto-activate lần đầu cài

**VIP feature mandatory — không skip.**

- **Trước tiên kiểm tra lib**: `_AdmobWrapper` có sẵn cơ chế auto-activate 1-day không? Nếu có → dùng API đó, KHÔNG re-implement (tránh duplicate). Verify ở Step 1.
- Nếu lib chưa có:
  - Lưu flag `pref_first_launch_vip_granted` trong `SharedPreferences`.
  - Trong `Application.onCreate` sau khi `AdManager.initialize`, nếu flag chưa set → gọi API activate 1 ngày của lib → set flag.
  - Idempotent: lần mở thứ 2 không re-activate.

## Step 10 — UI/UX VIP management screen (chi tiết, mandatory)

**VIP feature mandatory — không skip. Step 2 đã audit có hay chưa: nếu có thì upgrade in-place, nếu chưa thì tạo mới.**

### 10.1 — Cấu trúc UI (bắt buộc đủ)

| # | Thành phần | Detail |
|---|---|---|
| 1 | Status header | Crown icon + text 2 dòng:<br>• Dòng 1: `VIP Active` hoặc `Free User`<br>• Dòng 2: `Until dd/MM/yyyy` (ẩn nếu free) |
| 2 | Activation date row | `Activated: dd/MM/yyyy HH:mm` (ẩn nếu free) |
| 3 | Expiry date row | `Expires: dd/MM/yyyy HH:mm` (ẩn nếu free) |
| 4 | Progress bar | `LinearProgressIndicator` thể hiện % thời gian còn lại (0 → 100%) — chỉ hiện khi VIP active |
| 5 | Countdown text | Dạng `12d 03h 24m 15s` — update mỗi giây bằng `CountDownTimer` |
| 6 | Button "Nhập mã VIP" | Mở `AlertDialog` input → user paste plain key → app `Base64-encode` rồi gọi `AdManager.activateVipByKey(base64)` → toast success/fail |
| 7 | Button "Watch ad → 3 days VIP" | Click → `AdManager.loadRewarded` → `showRewarded`. `onUserEarnedReward` → activate 3-day VIP bằng key 3-ngày Base64 (encode từ Section 0). Nếu rewarded load fail → fallback `AdManager.showInterstitial` rồi vẫn activate 3 ngày |
| 8 | Toolbar badge | Khi VIP active, hiển thị badge "VIP" (dạng chip nhỏ vàng/gold) trên toolbar của `MainActivity`. Khi free, ẩn badge |
| 9 | Date format | Dùng `DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.getDefault())` cho ngày, `DateFormat.SHORT` cho giờ |

- Thanh progress bar count down nên có animation xịn sò để theo dõi số ngày vip real time
- Phải có text box để cho phép user nhập key tuỳ ý, sdk đã support sẵn các dialog check valid/invalid rồi, hãy sử dụng chúng
- Phải có list các option nhận thưởng bên dưới UI text box nhập key, list view reward này bao gồm
+ UI Xem quảng cáo nhận vip 3 ngày => user click => show quảng cáo reward (fallback inter) => xem ad success sẽ tự kích hoạt 3 ngày
+ UI Mua VIP 30 ngày giá 0,5 USD (tự convert ra local currency) => UI này disable và user không click được => tôi sẽ làm sau
+ UI Mua VIP 90 ngày giá 1 USD (tự convert ra local currency) => UI này disable và user không click được => tôi sẽ làm sau
+ UI Mua VIP 1 năm giá 2 USD (tự convert ra local currency) => UI này disable và user không click được => tôi sẽ làm sau
+ UI Mua VIP trọn đời giá 3 USD (tự convert ra local currency) => UI này disable và user không click được => tôi sẽ làm sau
- Các UI mua VIP nên có icon gift/ad kế bên để minh hoạ rõ ràng
- mọi dialog phải tuân theo thiết kế material you
- Sau khi kích hoạt VIP thành công, UI VIP phải lập tức cập nhập UI mới, có confetti animation xịn sò
- Khi account VIP, phải luôn có button huỷ kích hoạt VIP (reset mọi VIP để về free), phải có material you dialog để user confirm
- Khi account FREE, button huỷ kích hoạt VIP sẽ bị disable và không thể click được

### 10.2 — Animation (bắt buộc đủ 5 cái dưới)

| # | Animation | Cách impl | Trigger |
|---|---|---|---|
| 1 | Pulse cho nút "Watch ad" | `anim_pulse.xml` (scale 1.0 → 1.05 → 1.0, repeat infinite) | onResume, cancel onPause |
| 2 | Slide-in từ dưới khi mở fragment | `R.anim.slide_in_bottom` | `onCreateAnimation` của fragment |
| 3 | Crown icon shimmer | `ObjectAnimator` rotate ±5° hoặc shimmer drawable | onResume, cancel onPause |
| 4 | Number count-up cho countdown | `ValueAnimator` chạy khi value thay đổi đáng kể (mỗi phút), không mỗi giây | Khi `CountDownTimer.onTick` chạm phút mới |
| 5 | Confetti / scale celebration khi activate thành công | `ObjectAnimator` scale 0 → 1.2 → 1.0 + alpha 0 → 1 trên crown icon (1 giây), kèm haptic feedback `VibrationEffect.EFFECT_CLICK` | Sau khi `activateVipByKey` hoặc `onUserEarnedReward` thành công |

Bonus (nice-to-have, không bắt buộc): ripple effect mặc định cho 2 button (đã có sẵn theo Material), gradient background động cho status header.

### 10.3 — Memory leak rule riêng cho VIP screen (KHÔNG dùng các pattern sau)

- **KHÔNG** `Handler.postDelayed` cho countdown — bắt buộc dùng `CountDownTimer`, gọi `cancel()` ở `onDestroyView`.
- **KHÔNG** giữ rewarded callback dạng `object : RewardedListener` mà capture `this` của fragment — dùng `WeakReference<Fragment>` hoặc clear callback ở `onDestroyView`.
- **KHÔNG** start animation trong `onCreate`/`onResume` mà không cancel ở `onPause`/`onDestroyView` — mọi `ObjectAnimator`, `ValueAnimator`, `Animation` đều phải `.cancel()` trong `onDestroyView`.
- **KHÔNG** dùng anonymous `Runnable` post lên `View.postDelayed` mà không `removeCallbacks` ở `onDestroyView`.

### 10.4 — Entry point

Thêm preference/menu item trong settings screen của project trỏ tới VIP fragment. Tên ưu tiên `FVipManagement` (Kotlin, prefix theo convention project nếu có).

### 10.5 — Che giấu VIP key

Plain key ở Section 0 — KHÔNG hardcode plain trong file `.kt`. AI phải Base64-encode trước rồi hardcode chuỗi Base64 vào `companion object` hằng số. KHÔNG thêm AES/NDK/ProGuard string-encrypt trừ khi user yêu cầu — Base64 là mức đã thống nhất.

## Step 11 — Self-review & cập nhật `<PROJECT_PATH>/doc/AD.MD`

Review duy nhất 1 lần, KHÔNG lặp 3 lần. Checklist:

- [ ] Mọi slot ad đã thay (grep tên SDK cũ không còn match)
- [ ] 2 build variant ở Section 0 đều xanh
- [ ] 5 policy rule đều PASS
- [ ] Consent đã wire ở Splash
- [ ] VIP 1-day auto-activate có flag chống re-trigger (hoặc đã dùng API có sẵn của lib)
- [ ] VIP screen có **đủ 9 thành phần UI** (10.1) + **đủ 5 animation** (10.2) + **0 vi phạm memory leak rule** (10.3)
- [ ] Toolbar badge "VIP" hiện đúng theo trạng thái
- [ ] Bảng so sánh trước/sau đã viết trong `doc/AD.MD`
- [ ] List "info cần user cấp" đã viết trong `doc/AD.MD`

Nếu có item FAIL → fix → check lại item đó (không re-check item đã PASS).

## Step 12 — Báo cáo cuối (1 lần, ≤ 20 dòng)

Format cố định, **chỉ 2 section**:

```
### Migrate Result
- Build: <variantDebug>=<PASS|FAIL>, <variantRelease>=<PASS|FAIL>
- Slots migrated: <N/M>
- Policy: <5/5 hoặc list rule fail>
- Memory review: <OK | list điểm nghi ngờ với file:line>
- VIP UI: <9/9 components, 5/5 animations | list missing>
- Files changed: <count>, lines +<X> -<Y>

### Open questions for user
- <key/id còn thiếu cụ thể>
- <decision pending nếu có>
```

KHÔNG lặp lại "3 round". Step 11 checklist PASS hết → dừng. Có FAIL thì fix tới khi PASS rồi mới báo cáo.
