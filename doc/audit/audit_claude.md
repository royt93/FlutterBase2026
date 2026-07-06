# Audit toàn diện SDK quảng cáo `applovin_admob_sdk`

> Người audit: Claude (Opus 4.8) · Ngày: 2026-07-05 · Phạm vi: `packages/ad_sdk/lib/` (8.4k LOC) + host usage (`lib/mckimquyen/widget/vip/`)
> Phương pháp: đọc trực tiếp phần lõi (`ad_manager`, `ad_config`, `ad_safety_config`, consent) + 4 agent audit song song từng subsystem, có hiệu chỉnh severity.

Backlog thực thi nằm ở `doc/task/` (scrum: `todo/` → `inprogress/` → `done/`). Mỗi finding dưới đây map tới một task `Txx`.

---

## 0. Tóm tắt điều hành

SDK đã **rất trưởng thành về kiến trúc**: provider abstraction sạch (`AdProviderAdapter`), safety layer 12 lớp (throttle/cap/CTR/cooldown), VIP stacking, splash flow chống treo, lifecycle observer phòng thủ tốt. Đây là nền tảng tốt.

Tuy nhiên, đối chiếu **7 yêu cầu của partner**, có **các lỗ hổng nghiêm trọng về consent/compliance và network resilience** khiến SDK **chưa sẵn sàng ship về mặt pháp lý**:

| # | Yêu cầu partner | Trạng thái | Mức rủi ro |
|---|---|---|---|
| 1 | Provider admob/applovin, Android + iOS | 🟡 Đạt phần lớn — thiếu ad-unit-id theo từng platform | Thấp |
| 2 | Work khi có mạng / không mạng | 🔴 **Chưa đạt** — không auto-recover khi mạng trở lại (chờ tối đa 5 phút) | Cao |
| 3 | Ad types chuẩn, đúng vòng đời, no memory leak | 🟡 Tốt nhưng có vài lỗ dispose/leak cần vá | Trung bình |
| 4 | Trial mode 1 ngày | 🟢 Đã có (`firstInstallVipGrace.day`) — cần hardening chống clock-rollback | Trung bình |
| 5 | Kích hoạt VIP by code | 🔴 **Chỉ validate local** (base64, decompile là lấy được key vô hạn) | Cao |
| 6 | Consent mọi quốc gia, chuẩn AppLovin + AdMob | 🔴 **Chưa đạt** — dialog tự chế KHÔNG phải CMP hợp lệ; UMP là opt-in; `npa` không hề set cho AdMob | Nghiêm trọng |
| 7 | Tuân thủ policy AdMob/AppLovin | 🔴 **Rủi ro cao** — impression splash app-open bắn TRƯỚC khi có consent | Nghiêm trọng |

**Kết luận:** Trước khi phát hành, bắt buộc xử lý nhóm **P0 (consent + network + VIP server-side)**. Nhóm P1 (lifecycle/memory, provider parity, trial hardening) xử lý ngay sau.

---

## 1. Consent & Compliance (REQ 6 + 7) — 🔴 NGHIÊM TRỌNG

### 1.1 [CRITICAL] Dialog consent tự chế KHÔNG phải CMP hợp lệ cho EEA/GDPR → **T01**
- `consent/consent_dialog.dart`, `consent/consent_manager.dart`, bật auto qua `AdConfig.autoShowConsentDialog=true` (`ad_config.dart:127`).
- SDK auto hiện một **dialog Cupertino nhị phân Allow/Reject** sau splash. Đây **không phải** Google UMP / IAB TCF CMP: không phát hiện vùng địa lý, không liệt kê purposes/vendors, **không ghi TCF consent string** mà các ad partner downstream đọc.
- Google **bắt buộc** dùng CMP được chứng nhận cho user EEA/UK. Dialog tự chế → **vi phạm GDPR/chính sách AdMob**.
- Flow UMP thật (`core/ump_consent.dart`, `AdManager.requestUmpConsent`) **có tồn tại nhưng là opt-in**, SDK không tự gọi trong `initialize()`.
- **Hướng sửa:** UMP là nguồn sự thật chính cho EEA; dialog tự chế chỉ dùng cho non-EEA (hoặc bỏ). Gate mọi ad-load theo `ConsentInformation.canRequestAds()`.

### 1.2 [CRITICAL] `npa` (non-personalized) KHÔNG bao giờ được set cho AdMob → **T02**
- `core/ad_consent.dart:58-90` (`applyConsentToProviders`): với AdMob chỉ set `tagForChildDirectedTreatment` + `tagForUnderAgeOfConsent`. **Không hề** thêm extra `npa=1` vào `AdRequest`, cũng không có ở adapter (grep xác nhận `npa` chỉ xuất hiện trong comment `ad_consent.dart:15`).
- Hệ quả: user bấm "Reject" ở dialog tự chế → **AdMob vẫn phục vụ personalized ads**. Comment doc tuyên bố "forwards ... AdMob `npa` extra" nhưng code không làm.
- **Hướng sửa:** khi `hasUserConsent=false` (và ngoài phạm vi UMP), truyền `AdManagerAdRequest`/`AdRequest(extras: {'npa': '1'})` ở tất cả load path của AdMob adapter.

### 1.3 [CRITICAL] Impression đầu tiên (splash App Open) bắn TRƯỚC khi có consent → **T03**
- `ad_manager.dart:591` `unawaited(loadAppOpenAd())` chạy ngay khi init xong; splash gọi `showAppOpenAd(bypassSafety:true)`. Dialog consent lại được lên lịch **sau splash** (`markSplashInactive` → `_maybeScheduleConsentDialog`, `ad_manager.dart:219-284`).
- Vậy **ad splash hiển thị trước khi user trả lời consent** → vi phạm "phải lấy consent trước request đầu tiên" cho EEA.
- **Hướng sửa:** chạy UMP trong splash trước `initialize()`/trước app-open; nếu `canRequestAds=false` thì không show app-open.

### 1.4 [HIGH] AppLovin thiếu CMP flow + thiếu tín hiệu COPPA → **T04**
- `ad_consent.dart:63-72` chỉ gọi `setHasUserConsent` + `setDoNotSell`. Không dùng AppLovin CMP / Terms & Privacy Policy Flow, không set cờ age-restricted (comment `:67` ghi 4.x bỏ `setIsAgeRestrictedUser` nhưng không thay bằng gì) → **child-directed không được báo cho AppLovin**.
- **Hướng sửa:** dùng AppLovin CMP (nếu app dùng AppLovin làm provider chính ở EEA) hoặc tài liệu hoá rõ ràng việc COPPA chỉ delegate cho AdMob; kiểm tra API AppLovin SDK hiện hành cho cờ tương đương.

### 1.5 [MEDIUM] Map sai cờ CCPA → COPPA → **T05**
- `ad_consent.dart:82`: `doNotSell` (CCPA California) được map vào `tagForUnderAgeOfConsent` (TFUA — về tuổi). Hai khái niệm trực giao. CCPA của AdMob dùng Restricted Data Processing (RDP), không phải TFUA.
- **Hướng sửa:** tách `isAgeRestrictedUser` (COPPA, app-level) và `doNotSell` (CCPA, user-level) thành tín hiệu độc lập; áp RDP cho CCPA.

### 1.6 [HIGH] Không có entry point Privacy Options bền vững / re-consent → **T06**
- SDK có `ConsentManager.showDialog` nhưng **không bắt buộc** host đặt nút "Privacy Settings" thường trực. Google yêu cầu user luôn có cách đổi consent.
- **Hướng sửa:** cung cấp API `showPrivacyOptions()` (UMP privacy options form) + tài liệu MUST + assert debug nếu thiếu.

### 1.7 [MEDIUM] iOS ATT: có sẵn nhưng phải wiring đúng thứ tự → **T07**
- `core/att_consent.dart` chuẩn (map status, xử lý zero-IDFA, degrade an toàn). Nhưng là opt-in; phải gọi ATT **trước** UMP trong splash, và cần key `NSUserTrackingUsageDescription` trong Info.plist.
- **Hướng sửa:** wiring ATT→UMP theo thứ tự trong splash; assert/log to nếu thiếu plist key.

---

## 2. Network / Offline (REQ 2) — 🔴 CHƯA ĐẠT

### 2.1 [CRITICAL] Không có connectivity listener → không auto-recover khi có mạng lại → **T08**
- `ad_manager.dart:847` chỉ **đọc** `ConnectionNotifierTools.isConnected` tại thời điểm load; **không** có `.listen()` nào. Khi offline, các `loadAppOpen/Interstitial/Rewarded/Banner` bị skip (`ad_manager.dart:869,1055,1140`).
- Khi mạng trở lại, slot rỗng cho tới khi **retry timer 5 phút** (`_retryIntervalMs = 5*60*1000`, `:77`) chạy. 5 phút là không chấp nhận được.
- **Hướng sửa:** subscribe `ConnectionNotifier` khi init; transition `false→true` gọi `_retryRefillAds()` + reload banner ngay.

### 2.2 [HIGH] Banner offline không có UI state + không tự reload → **T09**
- `widget/banner_ad_widget.dart` khi `!isConnected` return im lặng, `_allowed=false`, hiển thị shimmer/placeholder vô thời hạn, không có listener reload khi mạng về.
- **Hướng sửa:** phát state "offline" riêng; reload `_initBanner` khi reconnect.

### 2.3 [MEDIUM] `isConnected` trả `true` khi exception + không phân biệt lỗi mạng → **T10**
- `ad_manager.dart:845-850` catch mọi lỗi → `return true` (lạc quan). Adapter coi lỗi mạng như mọi lỗi khác → vào cooldown/backoff, không fast-retry.
- **Hướng sửa:** mặc định pessimistic (`false`) + log; nhận diện error code mạng để fast-retry (hoặc để connection listener lo).

---

## 3. Vòng đời & Memory leak (REQ 3) — 🟡 CẦN VÁ

### 3.1 [HIGH] Fullscreen ad single-use: nguy cơ double-show object đã dispose → **T11**
- `adapters/admob_adapter.dart` (show interstitial/rewarded): sau show → dispose + slot idle, nhưng không chốt object ngay đầu `show()`. Cuộc gọi `show` thứ hai trong lúc callback chưa fire có thể `show()` trên object đã dispose → crash. (Rewarded có `_rewardedInFlight` phần nào che; interstitial dựa `isShowing`.)
- **Hướng sửa:** null-out object **trước** khi show, hoặc dùng field "showing" chặn show thứ hai.

### 3.2 [HIGH] Banner: postFrameCallback dồn khi rebuild + cửa sổ recreate không dispose → **T12**
- `banner_ad_widget.dart:178-181` add postFrameCallback mỗi lần build khi `!_allowed && isInitialised` → nhiều `_initBanner`/load chồng nhau. `admob_adapter` banner có cửa sổ set `_bannerAd` mới trong khi cái cũ đang chờ dispose.
- **Hướng sửa:** cờ `_postFrameCallbackPending`; dispose banner cũ trước khi tạo mới.

### 3.3 [MEDIUM] `_eventStream` không đóng + `AdLoadingDialog` không pop khi destroy/reset → **T13**
- `ad_manager.dart:156-157` StreamController broadcast tạo 1 lần, `destroy()` không close → rò rỉ khi destroy/init lặp. `AdLoadingDialog.resetState()` zero cờ nhưng không pop dialog đang hiện → có thể chồng dialog.
- **Hướng sửa:** close + tạo lại stream ở destroy/init; pop dialog đang mở trong `resetState()`.

### 3.4 [LOW] Route observer re-subscribe khi đổi route + guard timer nhỏ → **T14**
- `banner_ad_widget.dart` didChangeDependencies subscribe theo route đầu, đổi route không re-subscribe. Splash budget timer / shimmer controller thiếu cancel-trước-khi-tạo (rủi ro thấp).
- **Hướng sửa:** unsubscribe→re-subscribe khi route đổi; cancel timer/controller trước khi tạo mới.

> Ghi chú hiệu chỉnh: finding của agent về `bypassVipGuard` bị gán CRITICAL "policy bypass" là **sai** — path đó **có hiển thị ad thật** (flow "xem ad → +N ngày VIP"), đúng policy. Chỉ ghi nhận là điểm cần làm rõ API (gộp vào T19), không phải lỗi vi phạm.

---

## 4. Provider parity (REQ 1) — 🟡

### 4.1 [MEDIUM] Ad-unit-id không tách theo platform (Android vs iOS) → **T15**
- `config/ad_config.dart:88-105`: `AdMobConfig`/`AppLovinConfig` chỉ 1 id/slot, không phân biệt Android/iOS. Production thường cần id khác nhau theo platform.
- **Hướng sửa:** thêm biến thể `androidX`/`iosX` (hoặc factory theo `Platform`), chọn tại init.

### 4.2 [MEDIUM] Không validate ad-unit-id (rỗng/định dạng) → **T16**
- `rewardedId` default `''` (`:93`), không cảnh báo; không kiểm định dạng `ca-app-pub-...` cho AdMob. Đã có sẵn `releaseFootgunWarnings` (`ad_manager.dart:99`) để mở rộng.
- **Hướng sửa:** thêm cảnh báo id rỗng/sai định dạng vào `releaseFootgunWarnings`.

---

## 5. Trial mode 1 ngày (REQ 4) — 🟢 CÓ, cần hardening

- **Đã có:** `FirstInstallVipGrace.day = Duration(days:1)`, default `auto` (30s debug / 1 ngày release), cấp 1 lần/ install qua `FirstInstallGuard` (Keychain iOS chống reinstall; Android conservative). Ad-free session đầu → boost retention.

### 5.1 [HIGH] Clock rollback tái kích hoạt trial + thiếu footgun nếu grace bị tắt → **T17**
- `vip/vip_entry.dart` `isActive` chỉ so `DateTime.now().isBefore(expiresAt)` (wall-clock). User chỉnh đồng hồ lùi → entry đã hết hạn "sống lại". `grantedAt` được lưu nhưng không dùng để phát hiện lùi giờ.
- Release build nếu `firstInstallVipGrace.disabled` thì trial biến mất âm thầm, không cảnh báo.
- **Hướng sửa:** nếu `now < grantedAt` (đồng hồ lùi) → coi entry đã tiêu thụ; thêm footgun warning release khi grace disabled.

---

## 6. VIP by code (REQ 5) — 🔴 CHƯA AN TOÀN cho production

### 6.1 [HIGH] Chỉ validate LOCAL, key base64 dễ decompile → **T18**
- Host: `lib/mckimquyen/widget/vip/vip_keys.dart` giữ map key→Duration, **base64 (không mã hoá)**. Bất kỳ ai decompile lấy được key (vd 30 ngày) và redeem **vô hạn**. `AdConfig.vipKeyValidator` nếu `null` chấp nhận mọi key (demo).
- **Hướng sửa:** `vipKeyValidator` phải gọi **backend** (Firebase Function…) kiểm one-time-use / quota / device binding. Tài liệu MUST + (khuyến nghị) assert chặn ship với validator local-only.

### 6.2 [MEDIUM] Robustness: negative-duration, entry rác, clarity của stack cap → **T19**
- `vip/vip_manager.dart addVip` không guard `duration <= 0` (âm → entry chết âm thầm). Entry hết hạn tích tụ (lazy purge). `maxVipStackDuration` chỉ áp cho path `stack:true` (cần tài liệu rõ). API `bypassVipGuard/vipAutoGrant` cần đặt tên/tài liệu rõ ràng hơn.
- **Hướng sửa:** assert/clamp duration dương; purge eager entry hết hạn; tài liệu hoá cap + API VIP.

---

## 7. Safety / Policy layer (REQ 7) — 🟢 phần lớn tốt

`core/ad_safety_config.dart` đã có: throttle 60s, cap session/hour/day (6/3/5), warm-up 10s, cold-start gate, rapid-resume, CTR fraud (>30% → progressive cooldown 30m→24h), `dryRun` release footgun. App Open không chồng modal (`AdScreenRouteLogger.isDialogOnTop`, SDK 1.0.23). **Đây là điểm mạnh, chỉ cần giữ.** Rủi ro policy thực sự nằm ở **consent (mục 1)**, không phải ở safety.

> Lưu ý tuning: `maxFullscreenAdsPerSession=6` > `maxFullscreenAdsPerDay=5` → day là ràng buộc thực. Không phải bug, nhưng nên rà lại cho nhất quán.

---

## 8. Testing (REQ tất cả) — 🟡 → **T20**

`packages/ad_sdk/test/` đã có 200+ test. Cần bổ sung test cho: npa propagation, consent gating trước impression, connectivity-reconnect refill, single-use dispose guard, clock-rollback trial, server-validator path. Không mark bất kỳ task nào "done" nếu test tương ứng đỏ.

---

## 9. Thứ tự ưu tiên đề xuất

- **P0 (chặn phát hành):** T01, T02, T03 (consent) · T08 (network reconnect) · T18 (VIP server-side)
- **P1 (ngay sau):** T04, T05, T06, T07 · T09, T10 · T11, T12 · T15, T16 · T17
- **P2:** T13, T14 · T19 · T20
