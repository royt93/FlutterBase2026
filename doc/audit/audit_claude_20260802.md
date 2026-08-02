# Audit toàn diện `applovin_admob_sdk` + example, đối chiếu 7 yêu cầu production (2026-08-02)

**Người audit:** Claude (Opus 5), đọc source trực tiếp.
**Tham khảo độc lập:** `codex exec`, `claude -p`, `agy` (Gemini) chạy song song trên cùng repo, cùng bộ 7 yêu cầu.
**Phiên bản:** `packages/ad_sdk` = 1.2.4 (bản đang live trên pub.dev, score 150/160).

**Nguyên tắc của tài liệu này:** mọi finding dưới đây **tôi đã tự mở source xác minh tới từng dòng**, kể cả finding do agent khác nêu ra. Chỗ nào chưa xác minh được thì ghi rõ. Agent nêu sai thì ghi vào mục 4 chứ không im lặng bỏ.

## 0. Kết luận theo từng yêu cầu

| # | Yêu cầu | Đánh giá |
|---|---|---|
| 1 | Provider AdMob/AppLovin, chạy cả Android + iOS | **Đạt** — config tách per-platform đúng (`ad_config.dart:158-208`, `resolvePlatformAdUnitId` + fallback dùng chung) |
| 2 | Hoạt động khi có mạng và không mạng, phục hồi | **Một phần** — refill ads khi mạng về, nhưng **không** retry consent (C2) |
| 3 | 4 loại ad: vòng đời, không memory leak | **Một phần** — dispose/timer nhìn chung sạch, nhưng **không có mutex fullscreen chéo loại** (C3) |
| 4 | Trial 1 ngày | **Đạt trên iOS, yếu trên Android** (C5) |
| 5 | VIP bằng code, không server, chống decompile | **Đạt phần chống giả mạo**, hở phần chống chia sẻ lại (C6, C7) |
| 6 | Consent mọi quốc gia, đúng ở AdMob + AppLovin | **KHÔNG đạt với config mặc định** (C1, C2) |
| 7 | Tuân thủ policy AdMob/AppLovin | **Rủi ro thật** (C1, C3, C4) |

**Có nên dùng vào production app không?** Xem mục 5.

---

## 1. CRITICAL — config mặc định + dialog built-in ⇒ chặn 100% ad request trong release

Chuỗi nhân quả, xác minh từng dòng:

1. Default của `AdConfig`: `autoShowConsentDialog = true` (`ad_config.dart:344`), `autoRequestUmpConsent = false` (`:349`), `disableAppLovinCmpFlow = true` (`:353`).
2. `consentFootgunWarning()` (`ad_manager.dart:178-191`) trả về **non-null** khi cả 4 điều kiện đúng: `disableAppLovinCmpFlow==true`, `autoRequestUmpConsent==false`, `!umpRequested`, `!consentExplicitlySet`. Với default trên một process mới, cả 4 đều đúng.
3. Warning non-null → `_applyConsentFootgunGuard(isRelease)` (`ad_manager.dart:1266`) → trong release `_footgunBlocked = true` (`:630-632`).
4. `canRequestAds => _canRequestAds && !_footgunBlocked` (`:610`) ⇒ **false**.
5. `_footgunBlocked = false` chỉ xuất hiện ở **đúng một chỗ**: trong `setConsent()` (`:1414`).
6. Đường dialog built-in **không đi qua** `setConsent`: `ConsentManager` gọi thẳng `applyConsentToProviders` (`consent_manager.dart:110`). `grep` toàn bộ `lib/src/` không có call `setConsent(` nào từ `ConsentManager`.

**Hệ quả:** một consumer bật đúng cách mặc định (dialog built-in, "no code required" theo README) và ship release → `canRequestAds` false vĩnh viễn → **doanh thu ads bằng 0**, và **im lặng**: `assert(false, ...)` ở `:1270` bị strip trong release, chỉ còn một dòng `SafeLogger.w`.

**App host của repo này KHÔNG bị**, vì `splash_screen.dart` gọi `requestUmpConsent()` (dòng 207) **trước** `initialize()` (dòng 314) → `_umpRequested = true` → warning bị triệt. Đây chính là lý do lỗi sống sót: đường mà tác giả tự dùng hàng ngày không đi qua nó.

**Sửa:** cho `ConsentManager._setInternal` clear `_footgunBlocked` (hoặc route qua `setConsent`), và/hoặc cho `consentFootgunWarning` chấp nhận `autoShowConsentDialog == true` + `hasBeenAsked` là một consent flow hợp lệ.

## 2. HIGH — consent không được retry khi mạng trở lại

`ad_manager.dart:2612-2630` — `_onConnectivityChanged` chỉ hành động ở chuyển tiếp offline→online, và làm đúng 3 việc: `_retryRefillAds()`, `preloadBanner()`, bump `initRevision`. **Không** gọi lại `requestUmpConsent()`.

Trong khi đó `ump_consent.dart:105-118`: khi `requestConsentInfoUpdate` lỗi hoặc quá 20s (đúng ca offline), flow trả về `canRequestAds` lấy từ `ConsentInformation.instance.canRequestAds()` — tức **giá trị cached của UMP**, không phải hard-code `true`. Hướng bảo thủ này **đúng**.

**Hệ quả:** user EEA/UK mở app lần đầu khi **không có mạng** → không lấy được consent form; khi mạng về, ads được refill nhưng form **không bao giờ** được thử lại trong process đó. Không phải "serve ads không consent" (gate vẫn giữ), nhưng là ca mà yêu cầu 2 và 6 cùng nhắm tới và SDK không xử.

**Sửa:** thêm `requestUmpConsent()` vào nhánh reconnect khi lần trước thất bại.

## 3. HIGH — không có mutex fullscreen chéo loại ⇒ ad xếp lên ad

| Hàm | Guard hiện có |
|---|---|
| `showAppOpenAd` (`ad_manager.dart:1891,1899`) | kiểm **cả** `interstitialSlot.isShowing \|\| rewardedSlot.isShowing`, **và** `AdLoadingDialog.isShowing \|\| AdScreenRouteLogger.isDialogOnTop` ✓ |
| `showInterstitial` (`:2034`) | **chỉ** `interstitialSlot.isShowing` ✗ |
| `showRewarded` (`:2237`) | **chỉ** `_rewardedInFlight \|\| rewardedSlot.isShowing` ✗ |

Nên App Open được bảo vệ, còn interstitial và rewarded **không** chặn nhau và không chặn App Open. Host gọi `showInterstitialAd()` trong lúc rewarded đang chiếu → hai fullscreen xếp lên nhau. `AdSafetyConfig.canShowFullscreenAd()` là gate **tần suất theo thời gian**, không phải mutex theo trạng thái, nên không thay thế được.

Đây là **vi phạm policy** của cả AdMob và AppLovin (ad stacking / interstitial trên ad khác), loại dễ bị flag khi review.

**Sửa:** một guard dùng chung `anyFullscreenShowing` cho cả 3 đường show.

## 4. HIGH — trên AdMob, resume nạp lại banner bỏ qua gate consent/VIP/cap

- `admob_adapter.dart:1224-1244` — `onAppResumed()` gọi thẳng `loadBannerIfNeeded(width)` khi banner từng lỗi.
- `loadBannerIfNeeded` (`admob_adapter.dart:~924-938`) chỉ kiểm `cfg == null`, ad đã tồn tại, và `bannerSlot.beginLoad()`. **Không** kiểm `canRequestAds`, VIP, daily cap, connectivity.
- Có sẵn seam `canReload` khai ở `admob_adapter.dart:72` (`() => true`) nhưng `grep` cho thấy **chỉ AppLovin dùng** (`applovin_adapter.dart:395,438,676,705`). Trên AdMob nó là **dead code**.

**Hệ quả:** sau một lần banner lỗi, mỗi lần resume phát một ad request kể cả khi `canRequestAds == false` (vi phạm UMP) hoặc daily cap đã đạt. VIP thì widget không hiển thị banner nên user không thấy, nhưng **request vẫn đi ra** — đó là vấn đề policy, không phải UX.

**Sửa:** cho AdMobAdapter thật sự consult `canReload`, hoặc gate ngay trong `loadBannerIfNeeded`.

## 5. MEDIUM — trial 1 ngày và chống tái dùng key không bền trên Android

- `_redeemed_key_ledger.dart:45` — `isRedeemed` trả `false` ngay nếu không phải iOS; `markRedeemed` no-op tương tự. Ledger bền **chỉ có trên iOS** (Keychain, sống sót uninstall theo thiết kế).
- `_first_install_guard.dart` — cùng hình: anti-bypass dựa Keychain, iOS-only.

Trên Android, cả hai dựa vào `AdPreferences` (SharedPreferences). `CLAUDE.md` nói Android được che bằng Auto Backup (`dataExtractionRules` phục hồi `FlutterSharedPreferences.xml` khi cài lại qua Play). Nhưng Auto Backup **không** chống "Xoá dữ liệu" trong Settings, và chỉ hoạt động khi app cài từ Play + backup đang bật + cùng tài khoản Google.

**Hệ quả:** trên Android — nền tảng phần lớn user — xoá dữ liệu app là lấy lại trial 1 ngày và dùng lại key VIP cũ.

## 6. MEDIUM — key VIP không có expiry, không bind device/bundle, không thu hồi được

`signed_vip_key.dart:50-119`. Payload là `"<seconds>|<keyId>"`, chữ ký Ed25519, private key không ship.

**Phần đạt:** không thể **giả mạo key mới** bằng cách decompile app — chỉ public key nằm trong binary. Đây đúng là yêu cầu 5 và SDK làm đúng.

**Phần hở:** key không chứa thời điểm hết hạn, không bind bundle-id, không bind device. Một key rò lên mạng có giá trị **vĩnh viễn cho mọi máy**; `redeemSignedKey` chỉ chặn tái dùng **trên cùng một device** (và trên Android thì như C5). Không có kênh revocation offline. Docstring `:70-78` đã tự thừa nhận giới hạn này — trung thực, nhưng vẫn là rủi ro doanh thu thật khi phát key cho người dùng.

**Giảm nhẹ khả thi không cần server:** nhúng `expiresAt` vào payload đã ký (key hết hạn sau N ngày kể từ lúc mint), và/hoặc nhúng bundle-id.

## 7. MEDIUM — `maxVipStackDuration` mặc định là **không giới hạn**

> **ĐÍNH CHÍNH (cùng ngày, khi triển khai bản sửa):** phần "chỉ chặn đường `stack: true`" dưới đây **SAI**. Tôi trích docstring của `ad_config.dart` thay vì đọc code. Thực tế `VipManager.addVip` **đã clamp cả hai đường** từ lâu (`vip_manager.dart`, nhánh single-entry). Chính docstring mới là thứ lỗi thời, và đã được sửa. Grant migration year-2099 đúng là không bị clamp, nhưng vì nó tạo `VipEntry` trực tiếp chứ không qua `addVip` — không phải vì đường non-stack không được cap.
>
> Đây là lần thứ tư trong phiên tôi tin tài liệu thay vì đọc code. Giữ nguyên đoạn sai bên dưới để thấy rõ sai ở đâu.

`ad_config.dart:403-415` — mặc định `null` = uncapped, và docstring tự cảnh báo: nó **chỉ** cap đường `stack: true`; `addVip`/`redeemVip` không-stack cấp thẳng `now + duration`, **không bao giờ** bị clamp. Trần duy nhất còn lại là `_maxSeconds` trong `signed_vip_key.dart` = **~100 năm**.

Host repo này set 90 ngày (`splash_screen.dart:281`) nên an toàn. Consumer không set thì một key mint sai (hoặc rò rỉ) cấp được VIP gần như vĩnh viễn.

## 8. LOW — example ship key demo thật

`example/lib/main.dart:119-123` có public key demo + các code VIP demo đã ký, wire vào `VipRedeemScreen` (`:660`). Là example nên hợp lý, nhưng ai copy nguyên vào app thật thì mọi người dùng key demo công khai đó đều thành VIP. Nên có cảnh báo ngay tại chỗ.

---

## 9. Những gì agent nêu mà tôi bác bỏ hoặc hạ mức

- **"CRITICAL: không đổi được provider lúc runtime"** (codex). Chọn provider ở startup qua `AdConfig.provider` là thiết kế bình thường và đúng với yêu cầu ("apply provider admob/applovin, work cho cả android + ios" = chọn một provider và nó chạy cả 2 nền tảng), không phải đòi hot-swap. Hạ xuống *không phải defect*.
- **"HIGH: interstitial/rewarded không có watchdog"** (codex). Có thật là không có, nhưng repo đã cân nhắc và ghi lý do (commit `ccd37f9`, R10-E). Không phải oversight; là quyết định có chủ ý. Hạ mức xuống *cần đọc lý do trước khi đổi*.
- **Gemini**: chạy 2 lần đều `Error: timeout waiting for response`, **không đóng góp được finding nào**. Ghi lại để không ai tưởng nó đã xác nhận điều gì.

## 10. Những gì SDK làm tốt (không phải mọi thứ đều là defect)

- Config tách per-platform sạch, có fallback dùng chung (`ad_config.dart:158-208`).
- AdMob mặc định `_nonPersonalizedAds = true` và **reset về true khi re-init** (`admob_adapter.dart:48,362-363`) — bảo thủ đúng hướng.
- UMP có timeout 20s cho `requestConsentInfoUpdate` (`ump_consent.dart:105-108`) — không để splash treo vô hạn.
- Gate `canRequestAds` được consult ở 6 chỗ trong đường load/show.
- VIP chống clock-rollback bằng `grantedAt` anchor (`vip_entry.dart`).
- 675 unit/widget test + 21 integration test trên cả Android và iOS, CI 4 job.

---

## 11. Verdict: có nên dùng SDK này vào production app không?

**Có — nhưng KHÔNG dùng cấu hình mặc định, và phải sửa C1 + C3 + C4 trước.**

Lý do gọn:

- **Kiến trúc chắc.** Slot state machine, adapter 2 provider, watchdog, VIP Ed25519 offline, safety layer, gate consent, test suite 675 + 21 trên 2 nền tảng. Đây không phải wrapper viết vội.
- **Nhưng đường mặc định thì hỏng.** C1 nghĩa là consumer làm đúng theo README default sẽ ship ra bản release doanh thu 0 mà không có tín hiệu nào. Đây là lỗi nghiêm trọng nhất của cả audit, và nó tồn tại được vì app host tự dùng đường khác (gọi `requestUmpConsent` trước `initialize`).
- **Hai rủi ro policy thật:** C3 (ad xếp lên ad) và C4 (request ad khi consent chưa cho phép / đã quá cap). Cả hai đều là loại bị AdMob/AppLovin flag khi review, không phải lỗi mỹ phẩm.
- **Yêu cầu 5 (VIP không server) đạt phần khó nhất** — không giả mạo được key mới. Phần còn lại (chia sẻ lại key, Android xoá dữ liệu) là giới hạn cố hữu của mô hình không backend, và **đã được ghi trong docstring**; chấp nhận được nếu chấp nhận có ý thức, cộng thêm `expiresAt` trong payload thì giảm đáng kể.

### Thứ tự sửa đề nghị

1. **C1** — cho đường dialog built-in clear `_footgunBlocked`. Rẻ, và đang là lỗi mất doanh thu.
2. **C3** — một mutex fullscreen dùng chung cho 3 đường show. Rẻ, đóng rủi ro policy.
3. **C4** — AdMobAdapter consult `canReload`, hoặc gate trong `loadBannerIfNeeded`.
4. **C2** — retry consent ở nhánh reconnect.
5. **C7** — đổi mặc định `maxVipStackDuration` sang một giá trị hữu hạn, hoặc bắt buộc phải khai.
6. **C6** — nhúng `expiresAt` (+ bundle-id) vào payload đã ký.
7. **C5** — ghi rõ trong README rằng độ bền chống bypass trên Android yếu hơn iOS, để consumer quyết định có phát key hay không.

**Với app host trong repo này:** C1 không ảnh hưởng (đã gọi `requestUmpConsent` trước `initialize`), C7 không ảnh hưởng (đã set 90 ngày). Còn lại C3 và C4 **có** ảnh hưởng, và nên sửa trước lần release tiếp theo.
