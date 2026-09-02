# Audit độc lập — applovin_admob_sdk v2.9.11 (Claude, 2026-09-02)

Phạm vi: toàn bộ `lib/src/` (~35.000 dòng) + `example/lib/main.dart`. Đây là
audit độc lập sau 31+ vòng trước (xem `doc/audit/audit_round31_deep_consolidated.md`
làm baseline). Phương pháp: 7 nhánh đọc song song (dual-provider, offline,
widget lifecycle, VIP/trial, consent, ad_manager phần safety, ad_manager phần
show/policy), mỗi nhánh bắt buộc tự trace cơ chế thật qua source, không tin
report cũ, đối chiếu CHANGELOG để không báo lại lỗi đã fix. Sau đó tự tay
verify lại (đọc source trực tiếp) toàn bộ finding BLOCKER và phần lớn MAJOR
trước khi đưa vào báo cáo này — không đưa nguyên văn báo cáo agent con vào mà
không kiểm chứng.

---

## 1. BLOCKER

### B1 — `IabStorage.tcfAllowsPersonalisedAds()` không bắt được `TimeoutException`, phá chính ý đồ fix BLOCKER round-31

**File**: `lib/src/core/iab_storage.dart:219-227`

```dart
try {
  store = await _open().timeout(const Duration(seconds: 5));
} on StateError {
  return null;
}
```

`on StateError` chỉ bắt trường hợp "chưa đăng ký platform implementation"
(test-harness). Khi `_open()` chậm quá 5s (binder contention Android lúc
cold-start, hoặc iOS UserDefaults dưới tải — đúng nhánh code "chưa từng chạy
trên máy thật, CI chết từ 2026-08-09" mà chính comment trong file tự thừa
nhận), `.timeout()` ném `TimeoutException` — **không phải subtype của
`StateError`** trong Dart — nên thoát thẳng ra ngoài hàm thay vì fail-closed
(`return false`) như ý đồ round-31.

**Đã tự verify bằng cách đọc trực tiếp source** (không chỉ tin agent con):
xác nhận đúng cấu trúc try/catch trên, xác nhận `TimeoutException` không kế
thừa `StateError`.

**Kịch bản tái hiện & hậu quả theo từng call site (đã trace từng cái)**:
- `ad_manager.dart:3142` trong `initialize()` — được bọc bởi try/catch lớn
  hơn ở `ad_manager.dart:3309`, nên không crash app, nhưng **toàn bộ
  `initialize()` báo fail** (`onComplete(false)`) — nặng hơn hẳn hậu quả gốc
  (chỉ 1 lần đọc TCF chậm làm mất ads cả AdMob lẫn AppLovin cho cả phiên).
- `ad_manager.dart:4333` trong `_applyUmpConsentResult`, gọi từ API public
  `requestUmpConsent()` (`ad_manager.dart:4275`) — **không có try/catch bao
  ngoài tại điểm gọi**. README tài liệu hoá `requestUmpConsent()` là
  "best-effort, fails soft" — nếu timeout thật xảy ra, hợp đồng đó bị phá,
  host code gọi `await AdManager().requestUmpConsent()` nhận unhandled
  exception.
- `ad_manager.dart:7349` và `7471` — gọi qua `unawaited(...)`, không có
  try/catch → unhandled Future rejection (crash-reporting noise, cơ chế phục
  hồi UMP form bị bỏ dở âm thầm).
- Đối chứng: `ad_manager.dart:7213` (`_resumeAdWorkAfterConsent`) đã có sẵn
  `on TimeoutException` — bằng chứng tác giả trước biết rõ nguy cơ timeout ở
  đúng luồng consent này, nhưng chỉ vá 1/4 call site.

**Vì sao BLOCKER**: mục đích của fix round-31 là đảm bảo lỗi đọc TCF luôn
fail-closed (không bao giờ vô tình bật personalized ads cho user EEA đã từ
chối). Bug này khiến đúng nhánh lỗi có xác suất cao nhất (timeout kênh, nhất
là trên iOS — nhánh chưa từng kiểm chứng trên thiết bị thật) không đi vào
logic fail-closed nữa mà ném exception, hành vi thực tế phụ thuộc hoàn toàn
vào việc caller có bọc try/catch hay không (3/4 call site không có).

**Fix gợi ý** (không thuộc phạm vi audit, chỉ ghi nhận): đổi `on StateError`
thành `catch (e)` chung quanh dòng 220-221 cho fail-closed nhất quán, giữ
riêng nhánh `StateError` (không phải platform thật) trả `null` bằng cách
phân loại `e is StateError` bên trong catch.

---

## 2. MAJOR

### M1 — AppLovin Banner/MREC ghi "impression" + revenue tại thời điểm fill, không phải impression thật trên màn hình

**File**: `lib/src/adapters/applovin_adapter.dart:1972-1996` (`_handleWidgetAdLoaded`),
`lib/src/widget/banner_ad_widget.dart:622-639`, `lib/src/widget/mrec_ad_widget.dart:499-517`

Round-31 đã sửa đúng lỗi này cho AdMob (banner/MREC/native dùng `onAdLoaded`
làm proxy sai cho impression → đổi sang `onPaidEvent`/callback impression
thật), nhưng **không port sang AppLovin**. `WidgetAdViewAdListener` (plugin
`applovin_max`, class `AdViewAdListener`) hỗ trợ sẵn
`onAdRevenuePaidCallback` — đúng tín hiệu impression/ILRD thật, bắn tại thời
điểm hiển thị thật, không phải lúc load — **đã tự verify tồn tại trong
`applovin_max-4.6.4/lib/src/ad_listeners.dart:15` và
`max_ad_view.dart:230`**. Nhưng cả `banner_ad_widget.dart` lẫn
`mrec_ad_widget.dart` chỉ wire `onAdLoadedCallback/onAdLoadFailedCallback/
onAdClickedCallback/onAdExpandedCallback/onAdCollapsedCallback` — bỏ trống
`onAdRevenuePaidCallback` (đã tự grep xác nhận không xuất hiện trong 2
file). Thay vào đó, `applovin_adapter.dart:1988,1995` gọi
`AdSafetyConfig.recordBannerImpression()` + `_emitRevenueIfPresent()` ngay
trong `onAdLoadedCallback`.

**Kịch bản**: banner/MREC AppLovin auto-refresh ~30s/lần; mỗi lần preload
thành công — kể cả khi widget đã unmount, đang bị `setInlineAdsHidden` che
sau 1 fullscreen ad khác, hoặc app đang ở background — vẫn tính là
impression + phát `AdRevenueEvent`. Hậu quả: (a) dashboard ARPDAU/eCPM build
trên `events` stream bị thổi phồng, (b) mẫu số CTR-fraud detector (đã audit
kỹ ở round-31 cho path khác) bị pha loãng sai đúng kiểu round-31 mô tả,
chỉ khác provider. Doc comment mới sửa ở round-31
(`applovin_adapter.dart:167-170`, "never from a load callback") hiện **mâu
thuẫn trực tiếp** với chính dòng 1995 của cùng file.

### M2 — AppLovin Native không bao giờ phát `AdRevenueEvent`

**File**: `lib/src/widget/native_ad_widget.dart:436-480`

Còn nặng hơn M1: `NativeAdListener` (AppLovin) chỉ wire
`onAdLoadedCallback/onAdLoadFailedCallback/onAdClickedCallback` — hoàn toàn
không có `onAdRevenuePaidCallback` dù plugin hỗ trợ
(`max_native_ad_view.dart:225`, đã tự verify). So sánh AdMob native
(`admob_adapter.dart` wire đủ `onPaidEvent`) — Native AppLovin có 0 revenue
event, 0 tín hiệu ILRD trong suốt vòng đời SDK.

### M3 — `AdBootstrap.bootstrap()` không có hard-cap timer, splash có thể treo ~150s khi mất mạng lúc mở app

**File**: `lib/src/core/ad_bootstrap.dart:89-127`, ví dụ minh hoạ tại
`README.md:452-458`

`bootstrap()` await tuần tự `requestUmpConsent()` (timeout 20s per call) rồi
`initialize()` (`adapter.initialize().timeout(20s)` +
`_kInitRetryDelays = [5s, 15s, 30s]`, `ad_manager.dart:1223-1227`). Không có
timer cấp cao nào race với toàn bộ chuỗi này, khác hẳn
`AdReadinessSplashController` (có `hardCapDuration = 8s`). Khi mất mạng hoàn
toàn lúc cold-start: tổng thời gian tệ nhất ≈ 20 (UMP) + 20+5+20+15+20+30+20
(4 lần init timeout xen 3 khoảng backoff) ≈ **150 giây** trước khi
`bootstrap()` mới resolve. Không crash, không leak — nhưng splash "đơ"
~2.5 phút nếu host copy đúng pattern README (dùng `bootstrap()` trần, không
race timeout riêng). Docstring có cảnh báo chung chung nhưng không nêu con
số cụ thể để dev nhận ra mức độ nghiêm trọng.

### M4 — `example/lib/main.dart:809`: thiếu lại đúng race đã fix ở `AdReadinessSplashController` (round-31), khiến App Open show sau khi đã điều hướng khỏi splash

**File**: `example/lib/main.dart:801-822` (`_showAppOpen`, callback
`onComplete` của `AdLoadingDialog.showAdBuffer`)

```dart
AdLoadingDialog.showAdBuffer(context, onComplete: () {
  if (!mounted) {           // THIẾU `_navigated ||`
    _goHome();
    return;
  }
  ...
  AdManager().showAppOpenAd(bypassSafety: true, ...);
});
```

`_hardCap` Timer (8s) gọi `_goHome()` → `_navigated = true` →
`pushReplacement`. Trong lúc transition đang chạy, `State` vẫn
`mounted == true` (Flutter chỉ dispose State sau khi route-transition xong).
Nếu `onComplete` fire đúng lúc đó, guard chỉ check `mounted` (vẫn `true`) —
đi tiếp gọi `showAppOpenAd`, hiển thị App Open **sau khi splash đã chuyển
sang HomePage**. `ad_readiness_splash_controller.dart:134` đã fix đúng race
này bằng `if (_navigated || !ctx.mounted)`, nhưng fix không được port sang
code mẫu tay-viết trong `example/` — đúng rủi ro mà chính comment round-31
cảnh báo ("code mẫu dễ bị app khác copy nguyên lỗi"). Hậu quả: ad bất ngờ
xuất hiện sau khi user tưởng đã "vào app" — sát dark-pattern.

### M5 — `canShowRewardedInterstitialAd()` thiếu check `AdLoadingDialog.isShowing`, không đối xứng với 2 hàm chị em

**File**: `lib/src/core/ad_manager.dart:6968-6985`

Đã tự đọc và xác nhận: `canShowInterstitial()` (dòng 6390) và
`canShowRewardedAd()` (dòng 7008) đều có
`if (AdLoadingDialog.isShowing) return false;`, nhưng
`canShowRewardedInterstitialAd()` (6968-6985) hoàn toàn không có dòng này.
`ad_screen.dart:292` dùng hàm này làm gate DUY NHẤT trước khi mở
`_showRewardDisclosure` (một `AlertDialog` thường, cùng root Navigator với
`AdLoadingDialog`).

**Kịch bản**: 1 luồng interstitial/rewarded khác đang show `AdLoadingDialog`
(non-dismissable, `barrierDismissible:false`, `PopScope(canPop:false)`).
Host poll `canShowRewardedInterstitialAd()` để bật nút RI → vẫn trả `true`
(thiếu check) → user tap → `_showRewardDisclosure` push dialog xác nhận
**chồng lên** loading dialog không thể tắt. Ad thật vẫn được chặn đúng (bên
trong `showRewardedInterstitialAd()` có check `AdLoadingDialog.isShowing`
riêng) nên không double-show ad thật, nhưng UI bị kẹt (2 dialog chồng nhau,
1 cái không thoát được, tap "Watch ad" không phản hồi) — trải nghiệm
broken/confusing.

### M6 — `AdScreenRouteLogger.isDialogOnTop` chỉ thấy `Route`, vô hình với popup dựng qua `Overlay` trực tiếp

**File**: `lib/src/core/ad_route_observer.dart:63-141`

Cơ chế chỉ đếm `PopupRoute` (dialog/bottom-sheet/Cupertino popup) qua
`didPush/didPop/didRemove/didReplace`. Không thấy được popup dựng bằng
`Overlay.of(context).insert(OverlayEntry(...))` trực tiếp (không phải
`Route`) — pattern rất phổ biến ở các package loading-indicator/toast/coach-
mark bên thứ ba (kiểu `flutter_easyloading`, `overlay_support`), và
`SnackBar` (dựng qua `ScaffoldMessenger`, không phải Route).

**Kịch bản**: app dùng `EasyLoading.show()` khi gọi API, đúng lúc app resume
từ background → `showAppOpenAdOnResume` không thấy overlay này (không phải
Route) → App Open đè lên loading indicator. Biến thể sâu hơn của lớp lỗi
round-28 (nested-Navigator) — round-28 vá được trường hợp Route lồng nhau,
nhưng giới hạn kiến trúc "chỉ bắt Route" vẫn còn nguyên và không được tài
liệu hoá ở README.

### M7 — Fix nested-Navigator/bottom-sheet (round-28) là "opt-in", không loại bỏ root cause

**File**: tham chiếu `README.md:228, 432`, cơ chế tại `ad_route_observer.dart:18-43`

Fix thật đòi hỏi host tự làm 2 việc: (a) gọi `showAdSafeModalBottomSheet`
thay vì `showModalBottomSheet` gốc, và (b) tự đăng ký thêm
`AdScreenRouteLogger()` vào `navigatorObservers` của **từng** Navigator lồng
nhau (bottom-nav tab, `ShellRoute`...). SDK không thể enforce việc này ở
runtime. Bất kỳ package UI bên thứ ba nào tự gọi `showModalBottomSheet` nội
bộ (modal picker, image-crop dialog, v.v.) tái tạo đúng lỗ hổng gốc mà host
dev không kiểm soát được — đây là "đã có escape hatch", không phải "đã loại
bỏ root cause".

### M8 — `bypassSafety` là tham số public không bị enforce vị trí gọi + audit trail chỉ ở RAM

**File**: `lib/src/core/ad_manager.dart:5910-5931` (chữ ký `showAppOpenAd`),
`lib/src/compliance/bypass_audit_trail.dart:60-93`

`bypassSafety` là param public của `showAppOpenAd`, gọi được từ **bất kỳ
đâu** trong host app, không chỉ splash. Doc comment tại chỗ khai báo tự thừa
nhận `callSiteTag` "purely descriptive... not enforces where it's allowed to
be called". Khi `bypassSafety=true`, code skip hẳn daily cap/30s(thật ra
60s)-throttle/per-placement cap, chỉ giữ invalid-traffic-pause. Nếu dev vô
tình/cố ý copy dòng gọi từ splash sang một CTA khác, App Open show không
giới hạn tần suất — vi phạm AdMob frequency/placement policy thật. Cơ chế
kiểm soát duy nhất là `bypass_audit_trail.dart` — ring buffer **200 entry,
chỉ lưu in-memory**, không persist: nếu bị lạm dụng ở tần suất cao (đúng
kịch bản cần bắt), entry cũ bị đẩy ra ngay, và app restart xoá sạch bằng
chứng. Cơ chế audit tự thua trước đúng kịch bản nó sinh ra để bắt.

### M9 — `remote_ad_safety_provider.dart`: `minSessionDurationBeforeAd` thiếu sàn `min: 1`, remote config giá trị 0 vô hiệu hoá gate chống bot

**File**: `lib/src/config/remote_ad_safety_provider.dart:102-103` (call),
`:58-73` (helper `posInt`, default `min = 0`)

Round-30 đã đặt `min: 1` cho 2 field "throttle" cùng lớp
(`minTimeBetweenFullscreenAds`, `minTimeAppOpenResume`) với lý do "giá trị 0
= tắt hẳn gate". `minSessionDurationBeforeAd` có đúng bản chất tương tự
(chặn hiển thị ad ngay khi session vừa mở — dấu hiệu bot/spam) nhưng dòng
gọi `posInt('minSessionDurationBeforeAd', max: 3600000)` không truyền `min`
→ dùng default 0. Nếu backend remote-config trả `{"minSessionDurationBeforeAd": 0}`
(bug serialize, hoặc MITM giữa app và backend) → `_canShowFullscreenAdStrict`
luôn pass gate này ngay từ mili-giây đầu session. Cùng lớp lỗi round-30 đã
nhận diện và vá cho 2 field khác, bỏ sót field thứ 3.

---

## 3. MINOR

- **`lib/src/utils/ad_preferences.dart:558`**: sample fill-rate/eCPM baseline
  (T97) dùng `DateTime.now().toIso8601String().substring(0,10)` (ngày lịch
  LOCAL) thay vì UTC — cùng lớp lỗi round-31 đã vá cho daily-ad-count nhưng
  bỏ sót ở đây. Severity thấp vì chỉ ảnh hưởng recommendation của
  `WaterfallTuner`/`SelfHealingObserver` (không gate hiển thị ad, không phải
  cơ chế anti-fraud thật, và theo round-31 module này chưa từng cho
  recommendation thật trên kiến trúc 1-install-1-provider).
- **Comment lỗi thời**: `ad_manager.dart:5976,6932`, `ad_safety_config.dart:324`
  ghi "30s throttle" nhưng default thật của `minTimeBetweenFullscreenAds` là
  60000ms (60s). Chỉ sai doc, cơ chế throttle bản thân đúng và không bypass
  được qua route khác (đã verify mọi entry point show đều qua
  `AdSafetyConfig.canShowFullscreenAd()`).
- **VIP/trial (đã tự verify là giới hạn kiến trúc chấp nhận được, không phải
  bug ẩn)**: trial 1-ngày (`FirstInstallVipGrace`) trên Android không có
  backstop chống uninstall+reinstall (chỉ dựa Android Auto Backup của host,
  ngoài phạm vi SDK); CRL (revocation) fail-open khi offline dài ngày (quyết
  định sản phẩm có chủ đích cho kiến trúc "no backend"); high-water-mark
  chống tua đồng hồ lưu plaintext SharedPreferences trên Android. Cả 3 điểm
  đều đã được chính codebase ghi nhận + phân tích trade-off trong comment từ
  các vòng trước — không đưa vào MAJOR vì không phải phát hiện mới, chỉ nhắc
  lại để đầy đủ theo checklist đề bài (mục 4, 5).

---

## 4. Đối chiếu checklist đề bài

1. **Dual provider AdMob/AppLovin**: kiến trúc 1-install-1-provider cố định
   (không fallback runtime), không phát hiện race condition mới trong
   identity-guard (đã phủ đủ AppOpen/Interstitial/Rewarded/RewardedInterstitial
   ở cả 2 adapter, RewardedInterstitial AppLovin no-op là đúng thiết kế vì MAX
   không có ad-unit type này). Vấn đề thật nằm ở **thiếu song song hoá tín
   hiệu revenue/impression** giữa 2 provider — xem M1, M2.
2. **Offline/online**: cơ chế retry/backoff/watchdog/connectivity-refill nhìn
   chung tốt, có trần rõ ràng, không leak Timer mới tìm được. Vấn đề duy nhất
   là **UX-freeze dài** ở `bootstrap()` — xem M3.
3. **Lifecycle/dark-pattern/leak/stacking**: dispose() các widget ad đã đủ
   guard (không leak mới). Vấn đề thật nằm ở **3 kẽ hở stacking cụ thể**:
   M4 (example splash), M5 (RI disclosure dialog), M6/M7 (Overlay-based
   dialog + root-cause bottom-sheet chưa loại bỏ hoàn toàn).
4. **Trial 1 ngày**: cơ chế chống lách (đổi giờ, xoá data) đã rất chặt trên
   iOS (Keychain + high-water-mark). Android chỉ có bảo vệ tầng OS
   (Auto Backup), là giới hạn đã biết — xem mục MINOR.
5. **VIP by-code offline**: Ed25519 verify đúng, không forge được từ app
   decompile, CRL domain-separation đúng, fix round-31
   (`RedeemedKeyLedger._writeChain` static) đã tự verify là đúng và còn
   nguyên. Không tìm BLOCKER/MAJOR mới.
6. **Consent GDPR/UK/US/COPPA**: nguồn consent thống nhất cho cả 2 provider
   (funnel `ad_consent.dart`), COPPA order đúng cho cả 2 adapter, CCPA/US-
   privacy áp dụng cho cả 2. Nhưng **B1 phá đúng lớp bảo vệ TCF fail-closed
   round-31 vừa thêm** — đây là finding nghiêm trọng nhất của toàn bộ audit
   này.
7. **Policy AdMob/AppLovin**: rủi ro thật nằm ở M8 (`bypassSafety` không
   enforce vị trí gọi) và M6/M7 (App Open đè lên UI khác) — cả hai đều là
   loại vi phạm "ad placement policy"/"frequency capping" nếu bị khai thác
   hoặc host tích hợp không cẩn thận.
8. **Bug khác**: M1/M2 (đo lường revenue sai/thiếu ở AppLovin) và M9 (remote
   config có thể tắt 1 gate anti-bot) là 2 nhóm bug độc lập ngoài checklist
   gốc.

---

## 5. Kết luận

**Có thể đưa vào production**, package có nền tảng an toàn tốt sau 31 vòng
audit (crypto VIP đúng, consent funnel thống nhất, lifecycle dispose sạch,
cơ chế retry/backoff có trần rõ ràng). Nhưng cần fix trước khi ship nếu
target có user EEA/UK thật:

- **Bắt buộc trước production (BLOCKER)**: B1 — sửa `on StateError` thành
  bắt exception chung ở `IabStorage.tcfAllowsPersonalisedAds()` để không phá
  hành vi fail-closed round-31 vừa thêm, đặc biệt quan trọng vì đường iOS
  liên quan chưa từng verify trên máy thật.

- **Nên fix sớm (MAJOR, ưu tiên giảm dần)**:
  1. M1/M2 nếu dashboard doanh thu/CTR-fraud dựa vào `AdEvent` stream —
     hiện số liệu AppLovin banner/MREC bị thổi phồng, Native AppLovin thiếu
     hẳn revenue signal.
  2. M5 — 1 dòng, dễ sửa, tránh UI kẹt thật khi 2 luồng ad chạy gần nhau.
  3. M9 — 1 dòng (`min: 1`), đóng lỗ hổng remote-config tắt gate anti-bot.
  4. M4 — port đúng fix round-31 sang `example/main.dart` (code mẫu, nhưng
     dễ bị copy nguyên lỗi vào app thật).
  5. M3 — thêm hard-cap tuỳ chọn cho `bootstrap()` hoặc sửa ví dụ README,
     tránh splash "đơ" 2.5 phút khi mất mạng lúc mở app.
  6. M6/M7/M8 — khó fix triệt để trong kiến trúc hiện tại (giới hạn cấu trúc
     Route-based/API public), nhưng nên **tài liệu hoá rõ trong README**
     (hiện chưa có) để host tích hợp biết giới hạn và tự phòng ngừa.

Không có finding nào ở mức đủ nghiêm trọng để nói "không nên dùng" — nhưng
B1 nên coi là gate cứng trước khi release tiếp, vì nó trực tiếp làm suy yếu
đúng compliance fix quan trọng nhất của vòng audit ngay trước đó.
