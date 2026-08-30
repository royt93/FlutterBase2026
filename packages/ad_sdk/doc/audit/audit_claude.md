# Audit độc lập `applovin_admob_sdk` — Claude, Round 5

**Ngày:** 2026-08-22
**Version:** local `pubspec.yaml` = **2.3.0**; pub.dev latest = **2.3.0**.
**Phương pháp:** 5 lane đọc source song song (consent/privacy, VIP+trial security, ad lifecycle/leak, offline+native, policy+example) + tự re-verify `file:line` cho mọi finding Blocker/Major trước khi ghi vào đây. Đọc lại 3 file audit round 4 để không re-litigate finding đã đóng. Không sửa source trong vòng audit này.

## Gate thực chạy

| Kiểm tra | Kết quả |
|---|---|
| `flutter analyze` (ad_sdk) | **0 issues** |
| `flutter test` (ad_sdk) | **891/891 pass**, exit 0 |
| `flutter analyze` + `flutter test` (example) | 0 issues, 25/25 pass |
| Archive pub.dev 2.3.0 vs `lib/` local HEAD | **byte-identical** (chỉ lệch `.DS_Store` không được publish) — bản published ĐÃ chứa toàn bộ audit fix của `8f34d01` |
| **CI GitHub Actions** | **Run success cuối cùng: 2026-08-02.** Mọi run từ 2026-08-09 tới nay fail sau 5-7s vì billing, kể cả 4 commit của v2.3.0 |

**Hệ quả quan trọng:** gate xanh ở trên là **local, Dart-only**. Suite `example/integration_test/` (26 file) chưa hề chạy trên CI cho code của 2.3.0; Android đã verify tay trên Pixel 7 Pro, **iOS chưa verify với 2.3.0**. Cả 2 job `sdk-integration` và `sdk-integration-ios` đều chưa từng chấm bản này.

## Kiến trúc: không có native code riêng

`packages/ad_sdk/` **không có** `android/` và `ios/`; `pubspec.yaml` không khai báo block `plugin:`. Đây là **pure-Dart package** wrap 8 pub dependency. Zero MethodChannel tự sở hữu ⇒ zero khả năng lệch parity Android/iOS ở tầng SDK này (câu hỏi native parity: **PASS by construction**). `MissingPluginException` duy nhất có thể xảy ra là từ dependency, và mọi call đó đều được catch (GAID `ad_manager.dart:1573`, ATT `:1746`, PackageInfo `vip_manager.dart:708`, connectivity `:3925`, UMP qua `runZonedGuarded` `:1904-1970`).

---

# VERDICT (đọc trước)

## **KHÔNG dùng SDK 2.3.0 vào production app ngay bây giờ.**

Lý do không phải vì kiến trúc yếu — kiến trúc **thực sự chắc**: mutex fullscreen phủ đủ 4 loại không có race check-then-show, freshness AdMob đủ 4 loại, gate `canRequestAds` kín 100% entry point kể cả đường bypass adapter, Ed25519 verify thật và không forge được, không rebuild storm, không `setState` sau dispose, teardown có single-source-of-truth.

Lý do là **3 Blocker** + một nhóm Major tập trung vào đúng một class lỗi: **đường exception / callback tới muộn / continuation sau `await`, và guard bất đối xứng** (guard đã tồn tại ngay trong codebase nhưng không được áp dụng ở chỗ kế bên). Class này cho ra các trạng thái **chết vĩnh viễn cả session mà không tự chữa** — không phải mất một impression.

Tổng công sức fix nhóm Blocker + Major P0: **~60-80 dòng**, gần như tất cả là copy pattern có sẵn sang chỗ thiếu. Không có finding nào cần redesign, trừ B-VIP-1 (clock budget model).

Điều kiện để đổi verdict sang CÓ: xem mục [Điều kiện ship](#điều-kiện-ship) ở cuối.

---

# BLOCKER

## BL1 — UMP gate kẹt đóng vĩnh viễn cả session, không đường tự chữa → 0 ad

**Evidence:** `lib/src/core/ad_manager.dart:2453` (`_umpAttemptFailed = result.error != null;`), hai đường retry duy nhất đều gate trên flag đó: `:3874` (backstop 5 phút) và `:3955` (reconnect). Nguồn của result: `lib/src/core/ump_consent.dart:171-176`.

**Đường reachable:** mạng chập chờn hoặc launch đầu tiên offline ở EEA →
`requestConsentInfoUpdate` complete từ cache, **không** error (bỏ qua nhánh `:109-118`) →
`isConsentFormAvailable()` trả `false` vì form chưa tải được → rơi vào `else` `ump_consent.dart:160-162`, `formError` giữ **`null`** →
return `UmpConsentResult(canRequestAds: false, status: required, error: null)`.

Về `requestUmpConsent`: `_updateCanRequestAds(false)`, và `_umpAttemptFailed = (error != null)` = **`false`**. Cả backstop 5 phút lẫn reconnect đều không chạy. `_canRequestAds` đóng cứng → **mọi load/show của cả 4 ad type đều bị chặn hết session**, kể cả khi mạng đã về đầy đủ. Chỉ restart app mới thoát.

Chú ý `umpInconclusive` ở `:2429` đã bắt đúng ca này về mặt *consent value* (`error != null || status == unknown`) nhưng flag *retry* ở `:2453` lại không dùng biến đó — chính chỗ lệch tạo bug.

**Tại sao là Blocker:** trigger là "first launch mạng yếu" — kịch bản thường gặp nhất trên mobile, không phải edge case; hệ quả là mất 100% doanh thu của phiên đó; không có đường tự chữa; và **không có test nào cover** (`test/ump_skip_branch_lockout_test.dart:84` chỉ cover nhánh skip).

**Minimum fix (1 dòng):**
```dart
_umpAttemptFailed = result.error != null || umpInconclusive || !result.canRequestAds;
```

## BL2 — Consent-footgun gate fail-OPEN: host AdMob có thể chạy zero consent flow mà không có cảnh báo nào

**Evidence:** `lib/src/core/ad_manager.dart:204-208`
```dart
if (!config.disableAppLovinCmpFlow ||
    config.autoRequestUmpConsent ||
    umpRequested ||
    consentExplicitlySet) {
  return null;
}
```
`disableAppLovinCmpFlow` được đọc **duy nhất một chỗ** trong toàn SDK: `lib/src/adapters/applovin_adapter.dart:428` — tức là flag **chỉ có nghĩa với provider AppLovin**, hoàn toàn vô nghĩa với AdMob.

**Đường reachable:** config `provider: admob` + `autoRequestUmpConsent: false` + `disableAppLovinCmpFlow: false`. Đây là config **hợp lệ, SDK nhận không kêu**. Khi đó điều kiện `!false` = `false` ⇒ hàm return `null` ⇒ `_applyConsentFootgunGuard` không chạy (`:2065-2081`) ⇒ `_canRequestAds` giữ default **`true`** (`:1012`) ⇒ user EEA/UK **bị request ads mà không có bất kỳ consent form nào**, và host **không nhận được cảnh báo** dù đang ở release build.

**Tại sao là Blocker:** đây là fail-open pháp lý (GDPR/UMP policy) ở đúng nhánh mà guard N2 được viết ra để chặn. Default config an toàn (`autoRequestUmpConsent: true`), nhưng SDK tự nhận là có safety net cho trường hợp host tắt auto — net đó có lỗ.

**Minimum fix:** bỏ điều kiện `!config.disableAppLovinCmpFlow`, hoặc chỉ áp dụng nó khi `config.provider == AdProvider.appLovin`.

## BL3 — `kQaTestDeviceHashes` hardcode trong package public, always-on cả release, không có đường opt-out

**Evidence:** `lib/src/config/ad_config.dart:218-227` (8 hash + đúng model máy trong comment), `:280-281` `effectiveTestDeviceIds` merge **vô điều kiện**; `lib/src/adapters/admob_adapter.dart:439-443` gọi `updateRequestConfiguration(cfg.effectiveTestDeviceIds)` **không** có gate `kDebugMode`/`isActuallyRelease()`. Cũng được re-apply ở mỗi consent change (`lib/src/core/ad_consent.dart:110`).

**Ba vấn đề riêng biệt:**
1. **Leak:** 8 AdMob device-id hash (định danh ổn định, không đổi theo lần cài) + model máy chính xác của team, publish công khai lên pub.dev.
2. **Mất doanh thu vĩnh viễn:** bất kỳ máy nào trong 8 máy đó — bán lại, cho người khác, tester dùng làm máy chính — sẽ **mãi mãi chỉ nhận test ad, 0 revenue**, và không chỉ với app của mình mà với **mọi app third-party** dùng package này.
3. **Surprise cho consumer:** một app bên thứ ba âm thầm ship 8 test device lạ trong binary release của họ. README **không hề nói** — chỉ có `CHANGELOG.md:11-12`.

Không phải vi phạm policy AdMob (test device không tính invalid traffic), nhưng là leak + revenue hole + hành vi không được document ở nơi consumer đọc.

**Minimum fix:** chỉ merge khi `!isActuallyRelease()`, **hoặc** thêm `AdMobConfig(mergeQaTestDevices: ...)` default `false` cho consumer ngoài, và chuyển fleet list về config của host app. Tối thiểu: document ở README.

---

# MAJOR

## Nhóm 1 — Consent / pháp lý

### MJ1 — Privacy flags của AppLovin được set SAU `AppLovinMAX.initialize()`
`ad_manager.dart:1999-2005` (adapter init) chạy trước `:2057` (`consentMgr.applyToProviders`) → `ad_consent.dart:83-84` (`setHasUserConsent`/`setDoNotSell`). Trên cold start bình thường (`_pendingConsentSettings == null`), `ConsentManager.bootstrap` chỉ `_load()` từ prefs (`consent_manager.dart:51-60`) — **không** apply xuống provider. Nên `_bridge.initialize(cfg.sdkKey)` (`applovin_adapter.dart:437`) chạy khi AppLovin **chưa nhận consent flag nào**. AppLovin MAX yêu cầu set privacy flags **trước** init. (COPPA thì đúng — được truyền qua param `isAgeRestrictedUser` ở `ad_manager.dart:2003`.)
**Fix:** gọi `applyConsentToProviders(consentMgr.adConsent, config: config)` ngay sau `bootstrap`, giữ `:2057` làm idempotent re-apply.

### MJ2 — `tcfConsentString` luôn trả `null` trên thiết bị thật; test lại pass nên che mất lỗi
`ad_manager.dart:697-700` đọc `SharedPreferences.getString('IABTCF_TCString')`. `shared_preferences ^2.5.0` legacy impl: Android đọc file riêng `FlutterSharedPreferences` (UMP ghi vào default `<pkg>_preferences`); iOS prefix mọi key bằng `flutter.` (UMP ghi `IABTCF_TCString` không prefix). **Không platform nào khớp.** Test `test/ad_manager_core_test.dart:2739-2749` dùng `setMockInitialValues` nên pass. Doc (`ad_consent.dart:19-23`) giới thiệu đây là escape hatch cho third-party SDK → third party nhận `null` và tưởng không có TCF session.
**Fix:** đọc native store thật, hoặc bỏ API + ghi rõ chưa hỗ trợ. Đừng để một API compliance giả.

### MJ3 — Hai đường retry UMP làm rơi `tagForUnderAgeOfConsent` (TFUA) và mọi test param
`ad_manager.dart:3877` và `:3957` gọi `requestUmpConsent()` **không tham số**, trong khi đường chính truyền đủ (`:1936-1942`). Default là `tagForUnderAgeOfConsent: false` (`:2346`). App child-directed / under-16 EEA: attempt đầu fail → retry gom consent **không** có TFUA → form sai loại, consent thu được không hợp lệ cho audience under-age. Cũng mất `debugGeography`/`testIdentifiers` → QA không lặp lại được.
**Fix:** cache params của lần gọi auto-UMP, replay ở cả 2 retry site.

### MJ4 — `RequestConfiguration.tagForUnderAgeOfConsent` chưa bao giờ được set cho GMA
`ad_consent.dart:111-123` cố tình bỏ trống TFUA; `config.umpTagForUnderAgeOfConsent` chỉ đi vào `ConsentRequestParameters` của UMP (`ump_consent.dart:90`). Grep toàn `lib/`: không chỗ nào set TFUA lên `RequestConfiguration`. Google yêu cầu signal này trên request configuration khi audience là under-age-of-consent → ad request AdMob hiện không mang nó.
**Fix:** thêm field vào `AdConsent`, hoặc truyền `config.umpTagForUnderAgeOfConsent` vào `applyConsentToProviders`.

### MJ5 — `AdManager._consent` stale → UMP re-run xoá âm thầm `doNotSell` (CCPA) và `isAgeRestrictedUser` (COPPA)
`ad_manager.dart:2431-2435` và `:2500-2504` build `AdConsent` mới từ `_consent.isAgeRestrictedUser` / `_consent.doNotSell`. Nhưng `_consent` **không** được cập nhật khi host dùng public API `ConsentManager.set()` (`consent_manager.dart:160-162`) hay `reset()` (`:175`). Kịch bản: host set `doNotSell: true` qua `ConsentManager.set` → backstop UMP retry (`:3877`) hoặc `showPrivacyOptions()` chạy → `setConsent(doNotSell: false)` → persist `false`, `_restrictedDataProcessing=false` (`admob_adapter.dart:577`), `setDoNotSell(false)` (`ad_consent.dart:84`). **CCPA opt-out bị mất im lặng.**
**Fix:** đọc `_consentManager?.adConsent ?? _consent` tại 2433/2502 — đúng pattern `_syncConsentToAdapter` đã dùng (`:2326`).

### MJ6 — Không invalidate ad đã cache khi personalization bị hạ cấp mid-session
Mọi `show*`/`load*` check `canRequestAds` (đủ kín), nhưng khi user chỉ **rút personalization** mà `canRequestAds` vẫn `true` (trả lời "Reject" ở dialog built-in, hoặc đổi ý qua Privacy Options mà vẫn còn legitimate-interest basis), `applyConsent` chỉ đổi flag cho **request tương lai** (`admob_adapter.dart:573`). `_appOpenAd`/`_interstitialAd`/`_rewardedAd` và `_bannerAdsByKey` đã load với `npa=0` vẫn được show/auto-refresh. AppLovin `applyConsent` là no-op hoàn toàn (`applovin_adapter.dart:571-576`). Chỉ có discard theo tuổi ad, không có discard theo consent.
**Fix:** trong `_syncConsentToAdapter`, nếu `hasUserConsent` chuyển `true→false` thì dispose các fullscreen slot chưa show + bump `initRevision`.

### MJ7 — COPPA AppLovin: chuyển `true` khoá ad vĩnh viễn trong session, không có đường phục hồi
`setConsent` đóng `_canRequestAds` khi provider AppLovin + `isAgeRestrictedUser=true` (`ad_manager.dart:2305-2309`); khi consent mới chuyển cờ về `false`, hàm chỉ apply provider flags (`:2310-2312`), **không mở lại gate**. Thay đổi/đính chính tuổi trong cùng process ⇒ cả 4 surface AppLovin ngừng hoạt động tới khi `destroy()` + `initialize()`. Đóng gate là *đúng* (MAX 4.x không có runtime API cho cờ này), nhưng thiếu đường thoát và không document.
**Fix:** khi child flag đổi chiều nào cũng dispose adapter + re-init sau khi consent mới đã persist; thêm test `false→true→false`.

### MJ8 — `requestUmpConsent` không có in-flight mutex → có thể chạy chồng nhiều consent flow
`:3877` và `:3957` đều `unawaited(requestUmpConsent())`; `_umpRequested = true` chỉ được set **sau** khi await xong (`:2395`). Hai caller (hoặc một caller + host tự gọi) cùng khởi động UMP khi retry trước chưa hoàn tất ⇒ hai request/form, đua ghi `_lastUmpResult` + gate + consent persistence. Là rủi ro consent UX/policy, đặc biệt với form bắt buộc.
**Fix:** shared in-flight `Future<UmpConsentResult>`; retry join future đang chạy.

## Nhóm 2 — VIP / trial (zero-backend)

**Khung đánh giá quan trọng:** thiết kế zero-backend + không có chống repack/root ⇒ attacker có root **cũng có thể patch APK để thay public key**. Nên mọi bypass state-local (MJ11, MJ12, MJ13) chỉ là *hardening*, không phải security boundary. Cái đáng lo là finding **không cần root**.

### MJ9 — Clock-forward poisoning: đặt đồng hồ tiến TRƯỚC lần chạy đầu → trial 1 ngày thành ~1 năm, KHÔNG cần root
**Evidence:** `vip_manager.dart:224-241` (`_effectiveNow`), `:257-260` (`resyncSessionClock`), `ad_manager.dart:3737-3744`.
`_effectiveNow()` chỉ clamp **một chiều** (chống lùi). Khi session anchor được (re)set — lúc construct `:56`, hoặc mỗi resume `:258` — `real ≈ expectedMs` nên `trusted = real` và giá trị đó ghi thẳng vào high-water mark `:239`, **không có trần nào**.

Kịch bản: máy mới cài → Settings đặt clock +1 năm (F) trước lần chạy đầu → mark = F, trial grant `[F, F+24h]` (`ad_manager.dart:1814-1817` → `addVip` dùng `_effectiveNow`) → sửa clock về thật (T). Từ đó `observedMs(F) > trusted(T)` ⇒ `_effectiveNow()` trả **F mãi mãi** (`:236-238`) ⇒ `isActiveAt(F)` luôn true, `_scheduleNextExpiry`/`_handleExpiry` cũng tính bằng F nên purge không bao giờ chạy. Với `redeemSignedKey`, clamp `maxStackDuration` là `now.add(cap)` = `F+90d` nên cũng vô hiệu.

---

#### ĐÃ FIX 2026-08-26 (round 25) — mục dưới đây là lịch sử, không còn là finding mở

Chủ sản phẩm mở lại MJ9 và nó đã được đóng. Cách đóng **không** phải bản
redesign "đếm thời lượng còn lại" mà mục này chứng minh là bất khả thi — mà là
tách hai câu hỏi mà `_effectiveNow()` trước đây trả lời bằng cùng một giá trị:

- **"Entry đã hết hạn chưa?"** vẫn dùng high-water mark, giữ nguyên → phòng vệ
  lùi giờ mạnh y như trước (đó là chiều duy nhất mà lùi giờ tấn công).
- **"Entry đã bắt đầu chưa?"** giờ neo vào đồng hồ **thô** của máy
  (`VipManager._isLive`, biên độ `futureGrantSlack` = 1 giờ). Attacker buộc phải
  đưa đồng hồ về mức dùng được để dùng máy, và ngay lúc đó grant chưa bắt đầu.

Guard cố ý **không** chạy trong `_purgeExpired()`: khách trả tiền mà máy chạy
nhanh giờ thì bị hoãn, không bị xoá vĩnh viễn. Chi tiết + test red-then-green:
`doc/audit/audit_round23_consolidated.md` mục "Round-25".

Còn lại (chấp nhận): lỗi đồng hồ thật khi app đóng vẫn có thể đẩy mark ra tương
lai và **đóng băng** thời gian còn lại của khách đã trả tiền. Đặt trần cho mark
sẽ sửa được nhưng trần không phân biệt được lỗi đồng hồ với lùi giờ cố ý, nên
đổi lại chính là abuse mà mark tồn tại để chặn. Ghi lại, không đánh đổi.

Phân tích gốc của lần hoãn (2026-08-22) giữ nguyên bên dưới vì nó vẫn đúng về
việc *bản fix nào* là bất khả thi:

**Bản fix từng được chốt ("đổi sang đếm thời lượng còn lại theo đồng hồ monotonic") KHÔNG thực thi được trong package này.** Monotonic clock duy nhất trong Dart thuần là `Stopwatch`, và nó chết theo process; package cố ý thuần Dart (không `android/`, không `ios/`, không MethodChannel) nên không đọc được uptime hệ thống. Đếm thời lượng bằng `Stopwatch` sẽ khiến VIP thành **vĩnh viễn** cho bất kỳ ai kill app — sai theo chiều ngược lại và tệ hơn hiện trạng. Chính `_effectiveNow`'s doc comment (`:219-223`) đã ghi: khoảng hở còn lại *"needs a native monotonic-uptime source to close and isn't attempted here"*, và `:198-201` ghi rằng đồng hồ bị đổi **trước lần chạy đầu** thì offline không thể phát hiện (chưa có mốc nào để so). Đây là giới hạn kiến trúc của yêu cầu "VIP không server/backend", không phải chỗ chưa làm.

**Đã cân nhắc và loại:**
- *Đếm theo giờ foreground* — miễn nhiễm với đổi giờ, nhưng đổi nghĩa sản phẩm ("1 ngày" thành "24 giờ dùng", có thể kéo hàng tháng) và VIP bán theo tháng không dùng được. Bị loại.
- *Thêm native uptime* — đúng gốc nhưng biến package thành plugin có native, rủi ro build cho mọi app consumer, và uptime cũng reset khi reboot nên vẫn phải kết hợp. Bị loại.

**Việc đáng làm khi quay lại — và nó KHÔNG phải chống cheat:** đặt trần cho high-water mark (bỏ mark khi nó đi trước giờ thật quá một ngưỡng, ví dụ 7 ngày). Giá trị thật của nó là vá nhánh **khách đã trả tiền bị mất VIP oan**: comment `:204-209` mô tả đúng ca này — đồng hồ máy nhảy tiến do lỗi thật (DST/NTP glitch, pin CMOS, máy reset ngày) rồi được sửa về, mark đóng băng ở tương lai rác, và VIP của khách bị đóng băng thời gian còn lại hoặc bị coi là hết hạn cho tới khi giờ thật đuổi kịp. Cơ chế chống-drift hiện tại chỉ bắt được edit xảy ra **trong lúc app đang foreground**; lỗi NTP khi app đang tắt thì không bắt được. Ưu điểm thực thi: ~20 dòng, **không đổi định dạng dữ liệu nên không cần migration**, do đó không có đường nào làm mất VIP người đã mua.

**Rủi ro giữ nguyên hiện trạng, nói thẳng:** VIP tắt *toàn bộ* ad surface, nên một người khai thác được = một người bị lấy khỏi doanh thu suốt thời gian đó, không phải mất một ngày trial. Khai thác chỉ cần vào Settings đổi ngày, không cần root. Đánh giá của chủ sản phẩm: tần suất thực tế rất thấp, và ưu tiên 9 mục rò rỉ lifecycle (ảnh hưởng mọi người dùng ở mọi phiên) trước là đúng thứ tự.

Doc comment `:219-223` **tự thừa nhận** residual gap ("A jump made, then the app killed and relaunched… anchors a fresh (bogus) session and isn't caught"), nhưng chỉ nhận chiều "user *mất* VIP", không nhận chiều "user *được* VIP vô hạn".

**Tại sao là Major (không phải Blocker):** không có exposure pháp lý/policy; chỉ là monetization bypass. Nhưng đây là finding **duy nhất không cần root**, nên là finding VIP đáng ưu tiên nhất.
**Fix đúng bản chất:** lưu **budget thời lượng còn lại** (giảm theo monotonic elapsed) thay vì `expiresAt` tuyệt đối. Fix rẻ tạm thời: khi mark đang "đóng băng" (`observedMs - real > slack`), dùng `real` (không dùng mark) để mint entry mới trong `addVip`.

### MJ10 — `redeemSignedKey` bắt buộc phải có mạng — trái yêu cầu sản phẩm "VIP activation phải work offline"
`vip_manager.dart:685-689` reject trước khi parse/verify; wiring ở `ad_manager.dart:1766-1769`. Ed25519 verify (`:713-721`), CRL cache (`:733`), ledger + grant (`:735-771`) đều 100% local. README tự mâu thuẫn: thừa nhận gate ở `README.md:885-890` nhưng gọi `redeemSignedKey` là "fully offline" ở `:1151`.
Nghịch lý làm gate này vô nghĩa cả về bảo mật: bắt buộc online lúc redeem nhưng **không** yêu cầu CRL tươi (xem MJ13) — nên nó chỉ phá UX, không mua được gì.
**Đây là finding round 4 (codex M1) vẫn mở, và cả codex lẫn agy round 5 đều re-confirm độc lập.**
**Fix:** xoá 4 dòng đó. Network chỉ dùng cho `refreshRevocationList`.

### MJ11 — Fallback entries store giả mạo được → tự cấp VIP vĩnh viễn (cần root)
`ad_preferences.dart:186-196` (FNV-1a, salt `ad_sdk_vip_integrity_v1` **commit trong repo**), `:247-264`, đọc ở `_vip_entries_store.dart:51-52` ngay sau khi secure read trả `null`. Checksum là hash **không khoá**, salt public ⇒ attacker tự tính được và ghi `ad_sdk_vip_entries_fallback_v1` với `expiresAt: 2099` ⇒ VIP vĩnh viễn. Code tự document là "tamper-deterrent, not cryptographic" — đúng, nhưng nên **chặn trần**: reject entry từ fallback/legacy nếu `expiresAt - grantedAt > maxVipStackDuration` (giới hạn forgery ở 90 ngày thay vì vĩnh viễn). Nặng hơn: `ad_sdk_vip_max_observed_clock_ms` (`:315-322`) và `ad_sdk_redeemed_vip_kids` (`:280-290`) là plaintext **không có cả checksum** — xoá/hạ mark là vô hiệu hoá toàn bộ phòng thủ anti-rollback.

### MJ12 — iOS: mark chống-rollback yếu hơn chính entitlement nó bảo vệ
Entries ở Keychain (`_vip_entries_store.dart:25-37`, sống qua uninstall) nhưng mark ở `SharedPreferences`/NSUserDefaults (`ad_preferences.dart:315-322`, **không** sống qua uninstall). Nhận VIP 30d → để hết hạn thật → lùi clock vào giữa `[grantedAt, expiresAt]` → uninstall + reinstall (mark mất, entry còn) → launch: `observedMs == null` ⇒ `isActiveAt(rolled-back)` = true ⇒ VIP sống lại, lặp vô hạn.
**Fix (diff nhỏ):** lưu mark vào cùng secure storage với entries.

### MJ13 — CRL không revoke được entry đã cấp; không có yêu cầu freshness
CRL verify **đúng** (Ed25519 + domain separation `CRL1|`, `signed_vip_key.dart:256-297`; replay CRL cũ bị chặn bằng `issuedAt` monotonic `vip_manager.dart:835-840`) nên MITM không forge được. Nhưng: (a) revoke một `kid` **không** xoá entry `SIGNED_<kid>` đã active (`:730-737` chỉ check lúc redeem) ⇒ key rò rỉ redeem trên 10k máy vẫn giữ nguyên window tới 90 ngày; (b) không có max-age ⇒ attacker chỉ cần **drop** request CRL là fail-open vĩnh viễn (`:806-810`, `:820-824`); (c) `_ensureCachedRevocationLoaded` chỉ chạy 1 lần/instance (`:783`).
**Fix (diff nhỏ):** sau khi apply CRL, purge entry có key `SIGNED_<KID>` (chú ý `normaliseKey` uppercase, `:323`, `:762`).

### MJ14 — CRL fetch không có timeout (bất đối xứng)
`vip_manager.dart:819` — `await revocationProvider.fetchSignedCrl()` không timeout, dù sibling cùng shape có: `ad_manager.dart:1701-1703` bound `fetchSafetyParamOverrides()` ở 5s. Host dùng `http.get` không timeout + `Timer.periodic(24h)` theo doc ⇒ stack pending future vô hạn.
**Fix:** `.timeout(const Duration(seconds: 10))` — nhánh catch `:820-822` đã fail-open sẵn.

## Nhóm 3 — Ad lifecycle / memory / trạng thái chết

### MJ15 — AdMob App Open: callback tới muộn null hoá ad MỚI → App Open chết cả session + 2 native ad leak
**Evidence:** `admob_adapter.dart:731`, `:746`, `:799`.
Chuỗi: watchdog hard-cap fire (`:793-803`) → `_appOpenAd = null` **không dispose** (leak #1) + `markShowFailed()` → AdManager `onDismiss(false)` → `loadAppOpenAd()` → ad MỚI gán vào `_appOpenAd`, slot = `ready` → callback GMA cũ tới muộn → nhánh late `:731` set `_appOpenAd = null` lần nữa, **lần này xoá ad mới** (leak #2), nhưng slot vẫn `ready`.
Kết quả: `showAppOpen` rơi vào `:705-711` (`ad == null`) trả `false` **mãi mãi**, và `_retryRefillAds` (`ad_manager.dart:3999`) chỉ refill khi `isIdle || isCooldown` ⇒ **không bao giờ tự chữa**.
`onFailedToShow` còn tệ hơn: `_appOpenAd = null` ở `:746` nằm **ngoài** nhánh late check ⇒ vô điều kiện.
**Fix:** nhánh late chỉ `_disposeAd(ad, ...)` cho local `ad`, **không chạm `_appOpenAd`**; watchdog `:799` dispose ad thay vì chỉ null.

### MJ16 — `showAdBuffer` set `_isShowing = true` trước `Navigator.of` mà không có try → khoá cứng MỌI fullscreen ad + treo splash
`ad_loading_dialog.dart:148` set `true`; `:156` (`Navigator.of`) và `:160` (`_pushDialogRoute`) có thể throw. Không try/catch. Mọi caller fire-and-forget: `ad_manager.dart:2948`, `ad_screen.dart:105`, `:226`, `ad_readiness_splash_controller.dart:124`.
Throw ⇒ `_isShowing` kẹt `true` ⇒ `_fullscreenBusyReason` (`ad_manager.dart:1071`) trả `'ad loading buffer showing'` vĩnh viễn ⇒ **cả 4 loại fullscreen bị chặn hết session**, và `onComplete` không bao giờ chạy ⇒ caller treo. Đường splash trong integration contract đi qua đúng hàm này.
Chú ý `show()` có đúng lỗ này nhưng caller duy nhất đã bọc try/catch + `resetState()` (`ad_manager.dart:3377-3390`); `showAdBuffer` thì không ai bọc.
**Fix:** try/catch quanh `:156-161` → reset 3 field + gọi `onComplete()`.

### MJ17 — `dismiss()` không bump `_generation` → dialog mồ côi, UI đóng băng
`ad_loading_dialog.dart:114-126` thiếu `_generation++` (so với `resetState()` `:66` có). `showRewardedAd` bypass path gọi `AdLoadingDialog.dismiss()` **vô điều kiện** ở `ad_manager.dart:3395` kể cả khi `show()` bị bỏ qua vì `ctx == null` (`:3362`). Trong 15s `_loadRewardedOnDemand` đó, `_fullscreenBusyReason` **không** bao gồm `_rewardedInFlight`, nên một resume có thể mở `showAdBuffer` → `dismiss()` giết route đó → timer buffer thức dậy, `myGen == _generation` (guard `:170` không bắt) → `finally :189-193` xoá sạch `_isShowing/_activeNavigator/_activeRoute`. Dialog push sau đó thành mồ côi: `barrierDismissible: false` + `PopScope(canPop: false)` + `dismiss()` early-return vì `!_isShowing` ⇒ **UI đóng băng**.
**Fix:** `_generation++` trong `dismiss()` (1 dòng) + `:3395` chỉ dismiss khi chính nó đã `show()`.

### MJ18 — AppLovin: reward BỊ MẤT nếu `onAdReceivedReward` tới sau `onAdHidden`
`applovin_adapter.dart:1141-1146` — `onAdHiddenCallback` gọi `cb?.call(RewardResult.skipped)` **vô điều kiện** rồi `_rewardedDone = null`; `onAdReceivedRewardCallback` `:1176-1177` chỉ chạy được nếu `_rewardedDone` còn non-null. MAX không bảo đảm thứ tự 2 callback này qua mọi network trong waterfall. AdMob tránh đúng bug này bằng cặp cờ `earned`/`fired` (`admob_adapter.dart:1072-1094`) và robust với **cả hai** thứ tự.
Không có double-grant ở cả 2 provider (đã verify) — chỉ có nguy cơ **mất** reward, im lặng, không đường phục hồi.
**Fix:** bê pattern `earned`/`fired` sang `_wireRewardedListener`; `onAdHidden` chỉ `fire(skipped)` khi `!earned`.

### MJ19 — `initialize()` không dispose adapter khi init thất bại → orphan adapter còn giữ native listener
`ad_manager.dart:1982` tạo adapter → `:2010-2021` `return` khi `!ok`, **không** gọi `adapter.dispose()`. `applovin_adapter.dart:421-423` wire listener native **trước** `await _bridge.initialize(...)`. Trên nhánh timeout 20s (`:2006`), native init vẫn có thể hoàn tất sau đó ⇒ adapter orphan có listener sống, callback của nó mutate slot của adapter đã bỏ. Retry tới 4 lần ⇒ tối đa 4 adapter orphan, mỗi cái ~15 `ValueNotifier`.
**Fix:** `await adapter.dispose();` trước `return`.

### MJ20 — Banner/MREC/native slot có thể kẹt `loading` vĩnh viễn (không có watchdog)
`ad_slot.dart:127-131` tự ghi: `beginLoad` không có timeout nội tại, phải `armLoadWatchdog`. Nhưng `admob_adapter.dart:1357` (banner), `:1500` (mrec), `:1613` (native) gọi `beginLoad()` **không arm watchdog** — trong khi 4 slot fullscreen đều có (`ad_manager.dart:2781, 3036, 3189, 3490`) và AppLovin adapter cũng có (`:654, 700, 942, 975, 1125, 1157`). Nếu `BannerAdListener` không fire, slot đứng `loading` mãi ⇒ mọi `beginLoad()` sau trả `false` (`ad_slot.dart:97`), `_retryRefillAds` (`ad_manager.dart:3999-4018`) **không quét banner/mrec/native slot** ⇒ shimmer placeholder chiếm chỗ vĩnh viễn (`banner_ad_widget.dart:321-334`).
**Fix:** thêm `slot.armLoadWatchdog('banner', const Duration(seconds: 30))` sau 3 chỗ đó.

### MJ21 — Race dispose-during-await: banner/mrec tạo ad cho key đã chết
- AdMob `admob_adapter.dart:1366`: `await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(...)`; nếu `disposeBannerInstance(key)` (`:204-209`, gọi từ `State.dispose()`) chạy trong lúc await, continuation `:1369` vẫn tạo `BannerAd` và ghi vào `_bannerAdsByKey[key]` ⇒ ad đó **không ai dispose nữa**, và closure ghi `.value` lên `ValueNotifier` đã dispose (`:1383`, `:1395`) ⇒ debug throw, release no-op.
- AppLovin `applovin_adapter.dart:1429` (banner) / `:1511` (mrec): continuation gọi `_bannerAdViewIdFor(key)` `putIfAbsent` ⇒ **hồi sinh notifier cho key đã dispose**, native AdView vừa tạo không ai `destroyWidgetAdView` ⇒ leak native + map phình.
Đây đúng là bug đã được fix **chỉ cho native** (`_disposedNativeKeys` `:295`, dùng ở `:298/307`) mà bỏ sót banner/mrec.
**Fix:** check liveness sau mỗi `await`, mở rộng tombstone-set sang banner/mrec.

### MJ22 — `installAdCrashGuard()` không idempotent + swallow crash của host (default ON)
`ad_config.dart:399` `enableCrashGuard = true`; `ad_manager.dart:1686` gọi mỗi lần `initialize()`; `ad_crash_guard.dart:51` **không có cờ `_installed`**, không có `uninstall` ⇒ mỗi cycle destroy→init bọc thêm một closure giữ `previousOnError` cũ (chuỗi dài vô hạn).
Nặng hơn: attribution bằng so string stack (`:18-19` `stack.toString().contains(_sdkPackage)`). Build `--obfuscate` mất tên package ⇒ guard **vô hiệu đúng ở build cần nó nhất**; ngược lại (build release mặc định, không obfuscate) một lỗi host có xen frame SDK bị nhận vơ ⇒ `return` `:58` / `return true` `:72` khiến lỗi **không tới `previousOnError`** ⇒ **Crashlytics mất crash**. Với một production app, mất observability là rủi ro thật.
Ngoài ra `_recoverSlots` (`:28-35`) thiếu `rewardedInterstitialSlot`, mrec và native slot.
**Fix:** cờ `_installed`; chỉ swallow khi `kDebugMode`, release thì log rồi vẫn chain xuống `previousOnError`; bổ sung slot còn thiếu.

### MJ23 — Slot kẹt `showing` vĩnh viễn cho interstitial / rewarded / rewarded-interstitial (cả 2 provider)
Không có show-watchdog cho 3 loại này (được document là cố ý: `admob_adapter.dart:951-958`, `applovin_adapter.dart:1041-1055`); `beginShow()` yêu cầu `isReady` (`ad_slot.dart:193`); `armLoadWatchdog` chỉ cứu `loading` (`:141`). Kết hợp với MJ22 (`_recoverSlots` thiếu slot) ⇒ callback native không tới là slot chết cứng + `_xDone` treo + ad object leak. Chỉ App Open có hard-cap watchdog.

### MJ24 — Watchdog App Open AdMob arm SAU `await ad.show()`
`admob_adapter.dart:774` nằm sau `await ad.show(...)` `:719`. Nếu platform call của `show()` treo không resolve, watchdog **không bao giờ được arm** — đúng cái hang mà nó tồn tại để chống. AppLovin không bị (`:767` sync).
**Fix:** arm watchdog trước `await`.

### MJ25 — `catch` của cả 4 `showX` AdMob không dispose ad object
`admob_adapter.dart:776-783`, `:942-947`, `:1126-1130`, `:1274-1277` chỉ `_xAd = null` + `markShowFailed()`; local `ad` mất ref ⇒ native ad leak. Path này thực: `gma_bridge.dart:335-342` `await setServerSideOptions(...)` trước show có thể throw.

## Nhóm 4 — Policy AdMob / AppLovin

### MJ26 — App Open on resume không phân biệt "user quay lại sau khi click ad"
`ad_manager.dart:3791-3800`: `resumed` → `showAppOpenAdOnResume()` vô điều kiện. Gate ở `ad_safety_config.dart:518-582` chỉ có fullscreen throttle, cold start, `_pendingResumeGate`, `minTimeAppOpenResume` (**default 5s**, `:86,137`), rapid resume — **không có gate nào theo `recordAdClick`** (`:621-642`).
Click banner/MREC/native (`banner_ad_widget.dart:505`, `mrec_ad_widget.dart:445`, `native_ad_widget.dart:352`) mở browser/Play Store ⇒ app paused ⇒ user về sau >5s ⇒ **App Open show ngay**. Cả AdMob và AppLovin coi đây là placement sai + rủi ro bị flag accidental-click. (Click ad fullscreen thì an toàn: busy mutex + throttle 60s + guard `ad_manager.dart:2917-2925`.)
**Fix:** lưu `_lastAdClickAt` trong `recordAdClick()`, block resume App Open nếu click xảy ra ngay trước lần background này (~30s).

### MJ27 — `bypassSafety: true` bỏ luôn CTR-fraud + suspicious-pause, không chỉ frequency cap
`ad_manager.dart:2832-2851`: `if (!bypassSafety)` bọc **toàn bộ** `canShowFullscreenAd()`, trong đó có `_suspiciousPauseUntil` (`ad_safety_config.dart:422-427`) và CTR anomaly (`:470-484`) — đúng 2 lớp chống invalid traffic. Hệ quả: splash App Open vẫn show dù account đang bị pause 30 phút–24h do click spam. `showAppOpenAd` là API public nên host gọi `bypassSafety: true` ở đâu cũng được; README:781 chỉ mô tả, không có code nào giới hạn về splash.
Phụ: `_canShowFullscreenAdStrict` dùng `DateTime.now()` thô (`ad_safety_config.dart:420`) ⇒ lùi clock cũng xoá được `_suspiciousPauseUntil` (cùng theme MJ9).
**Fix:** tách fraud-check ra khỏi caps; fraud-check chạy **cả khi** `bypassSafety`.

### MJ28 — `AdSafetyConfig.resetSession()` public, xoá cả fraud state đã persist — và example có nút bấm
`ad_safety_config.dart:667-692` reset `_clickTimestamps`, `_suspiciousViolationCount`, `_suspiciousPauseUntil` và `prefs.setSuspiciousCount(0)` ⇒ xoá sạch progressive cooldown đã lưu đĩa. Export public qua barrel. `example/lib/main.dart:1956` có nút "Reset session counters" ⇒ template mà consumer copy có sẵn nút vô hiệu hoá anti-fraud trong release.
**Fix:** `resetSession()` chỉ reset counter phiên; phần fraud chuyển `@visibleForTesting` hoặc gate `!isActuallyRelease()`. Sửa/label lại nút ở example.

## Nhóm 5 — Release engineering (không phải code, nhưng chặn production)

### MJ29 — CI chưa validate bất cứ gì kể từ 2026-08-09; iOS chưa verify với 2.3.0
Run success cuối: `2026-08-02`. Mọi run của 4 commit tạo nên 2.3.0 đều fail sau 5-7s (billing). ⇒ `sdk-integration` (Android emulator) và `sdk-integration-ios` (3 shard, Xcode) **chưa từng chấm bản published**. 26 suite integration tồn tại và có giá trị, nhưng bằng chứng duy nhất hiện có là verify tay Android trên Pixel 7 Pro. **iOS 2.3.0 = zero bằng chứng.** Với một SDK bán claim "work cho cả Android + iOS", đây là gap không thể bỏ qua trước khi ship.

### MJ30 — Toàn bộ `doc/` (1.7MB) — gồm 3 file audit bảo mật nội bộ — được publish lên pub.dev
`.pubignore` không loại `doc/`, `test/`, `tool/`. Archive 2.3.0 chứa `doc/audit/audit_{claude,agy,codex}.md` — tức là **bản đồ công khai các điểm yếu VIP-bypass còn mở**, kèm `file:line`, publish cho bất kỳ ai `pub cache` xuống đọc. Cộng thêm backlog nội bộ, task docs, và `doc/archive/WIFI_STRESSOR_STATS_DESIGN.md` (thiết kế app khác). `doc/` (1.7MB) còn to hơn `lib/` (904KB).
**Fix:** thêm `doc/`, `test/`, `tool/pinning_check_app/` vào `.pubignore` (giữ `doc/screenshots/` nếu `screenshots:` trong pubspec cần).

### MJ31 — `google_mobile_ads: ^7.0.0` trong khi latest là 9.1.0; bị chặn bởi Flutter pin
GMA Flutter 9.1.0 phát hành 2026-08-11; package pin `^7.0.0` (7.0.0 phát hành 2025-12-16). GMA 8/9 cần Dart `>=3.10.0` + Flutter `>=3.38.1`, mà CI pin Flutter 3.35.1 (Dart 3.9.x) không đáp ứng — đã document ở CLAUDE.md. Với production app: đang ở sau 2 major version của GMA SDK, và Google có lịch sử ngừng serve cho SDK version quá cũ. Đây là **nợ có deadline**, không phải nợ vô hạn. Nâng Flutter cũng nâng `environment` floor ⇒ breaking cho consumer ⇒ cần plan major version.

---

# MINOR (danh sách, đã verify hoặc evidence rõ)

| # | Finding | Evidence |
|---|---|---|
| m1 | `SimpleEventBus.listen()` replay `_lastEvent` không bọc try/catch (`fire()` thì có) — listener đăng ký muộn throw ra caller, làm gián đoạn startup | `event_bus.dart:20-24` vs `:30-40` |
| m2 | AVP2 bundle binding fail-**open** khi không đọc được bundle id | `vip_manager.dart:704-712`, `signed_vip_key.dart:205-222` |
| m3 | AVP1/AVP2 không domain-separate (verify chỉ `payload`, prefix không được authenticate); AVP1 không có expiry + không bundle binding ⇒ key AVP1 rò rỉ chạy **mãi mãi trên mọi app** cùng public key | `signed_vip_key.dart:162-168, 180-192` |
| m4 | Còn `DateTime.now()` thô trong path expiry: migrate legacy grantedAt (`vip_manager.dart:349`), `VipEntry.isActive/remaining` (`vip_entry.dart:45,53`), default `now` của `verifySignedVipKey` — là **public API export** nên host gọi trực tiếp dùng clock thô (`signed_vip_key.dart:200`) | như cột |
| m5 | `_lastUmpResult` / `_attRequested` không reset trong `_resetGuardState()` | `ad_manager.dart:2645-2671` |
| m6 | Race đọc `_umpRequested` khi auto-UMP chạy concurrent → footgun warning false-positive/negative | `:1932-1976` vs `:2395`, đọc ở `:2066` |
| m7 | iOS: `AdvertisingId.id(true)` vẫn có thể tự bật ATT prompt nếu đọc `trackingAuthorizationStatus` throw (`attStatus = null` ⇒ `shouldDeferGaidFetch` false) | `:1743-1759`, `:248-254`, `:1569` |
| m8 | Adapter init xoá tạm thời COPPA tag của AdMob (`RequestConfiguration` build lại, không merge) — hiện vô hại vì không có ad request ở giữa | `gma_bridge.dart:120-124` |
| m9 | Dialog consent built-in không phải CMP TCF nhưng vẫn có đường chạm user EEA khi UMP inconclusive | `consent_dialog.dart:30-59`, `ad_manager.dart:1297-1348` |
| m10 | CCPA: không đọc GPP / `IABUSPrivacy`, không map từ UMP US-states message; `doNotSell` chỉ set thủ công ⇒ `ComplianceReport` báo sai cho user California đã opt-out qua UMP | grep `lib/`: no `IABGPP` |
| m11 | UMP backstop retry **không bounded** (`_umpBackstopRetryCount` chỉ increment, không dùng làm cap) ⇒ retry vô hạn suốt session khi UMP fail dai dẳng | `:3874-3877` |
| m12 | Connectivity watch fail một lần là mất luôn fast-path (chỉ gọi 1 lần, không re-attempt) ⇒ `isConnected` vĩnh viễn `true` optimistic | `:3912` catch `:3926`, gọi 1 lần `:2114` |
| m13 | `initialize()` không có deadline tổng; 7 `await` không timeout (ATT status `:1745` — chính SDK bound call này ở 5s tại `:609`; prefs `:1690`; `vip.load` `:1769`; Keychain guard `:1803/:1826`; `ConsentManager.bootstrap` `:1846`; `applyToProviders` `:2057`; `PackageInfo` `vip_manager.dart:707`) | như cột |
| m14 | `rewardedInterstitialSlot` không được `dispose()` (AppLovin còn không `reset()`); `AdSlot._watchdogTimer` chỉ cancel trong `dispose()` không trong `reset()` ⇒ Timer 30s sống sót qua teardown | `admob_adapter.dart:537-539`, `applovin_adapter.dart:550-552`, `ad_slot.dart:232-235` |
| m15 | Expiry bị tính là "failure", đầu độc backoff (`markFailed()` thay vì `beginReload()`) | `admob_adapter.dart:701/892/1053/1206` |
| m16 | `isAdFresh` dùng wall-clock ⇒ clock lùi cho difference âm ⇒ "fresh" mãi | `admob_adapter.dart:611-614` |
| m17 | AppLovin **không có** freshness check ở cả load lẫn show; `lastLoadedAt` set nhưng không ai đọc. Asymmetry với AdMob không được document | `:717-720, 990, 1194` |
| m18 | `canShowInterstitial()`/`canShowRewardedAd()` không check freshness ⇒ host poll thấy `true` cho ad đã stale | `ad_manager.dart:3151`, `:3624` |
| m19 | Consent-gate của widget dispose ad **trước** khi rút khỏi tree ⇒ ~1 frame `AdWidget` còn trong tree khi native view đã destroy | `banner_ad_widget.dart:100-101`, `mrec:77`, `native:92` |
| m20 | AdMob banner/mrec/native callback không có guard sau dispose (AppLovin native thì có) | `admob_adapter.dart:1381-1400, 1519-1548, 1631-1660` |
| m21 | `_disposedNativeKeys` phình vô hạn, giữ strong ref tới mọi native `State` đã chết ⇒ leak tuyến tính với use-case ListView nhiều native | `applovin_adapter.dart:295, 335` |
| m22 | `_destroyWidgetAdViewWhenDetached` dùng `Future.delayed` không track/cancel ⇒ vẫn retry ~1.7s sau dispose, gọi bridge đã teardown | `applovin_adapter.dart:263` |
| m23 | `disposeMrecInstance` (AdMob) bỏ sót `_mrecRoutePausedByKey.remove(key)` (banner có, AppLovin có) | `admob_adapter.dart:268-272` vs `:207` |
| m24 | `BannerListenables` rò cho key có listenables mà không có slot (dispose-all chỉ iterate `_xSlotsByKey.keys`) | `admob_adapter.dart:543/548/555` |
| m25 | `NativeAdWidget` không `with RouteAware` ⇒ native ad vẫn "sống" khi route khác che (banner/MREC thì pause) | `native_ad_widget.dart:49` |
| m26 | `RevenuePanel.debugModeOverride` bật được panel doanh thu trong release (override thắng `kReleaseMode`), trái pattern `isActuallyRelease` dùng ở mọi nơi khác. `DebugAdOverlay` thì đúng | `revenue_panel.dart:34-46` vs `debug_ad_overlay.dart:60` |
| m27 | Example gọi `canShowFullscreenAd()` (có side effect) trong `build()` — đúng thứ docstring cấm, phải dùng `canShowFullscreenAdPeek()` | `example/lib/main.dart:1946-1952` vs `ad_safety_config.dart:361-369` |
| m28 | `AdLoadingDialog` không cancel được, tới 15s ở luồng VIP watch-ad (`barrierDismissible:false` + `PopScope canPop:false` + `show()` không timer) | `ad_loading_dialog.dart:80, 254, 101-111`, `ad_manager.dart:3267, 3378` |
| m29 | Example mô tả **sai** contract replay của `SimpleEventBus` ("only delivers" cho listener đăng ký trước) | `example/lib/main.dart:424-429` vs `event_bus.dart:14-24` |
| m30 | README Step 5 splash template thiếu `SimpleEventBus().remove(...)` (example có) ⇒ host copy README bị leak listener | `README.md:449-456` vs `main.dart:503-505` |
| m31 | README sai nhẹ về `dryRun` (liệt kê trong footgun list, thực tế `releaseFootgunWarnings` không kiểm và dryRun bị force `false` trong release) | `README.md:766` vs `ad_manager.dart:141-145`, `ad_safety_config.dart:326-334` |
| m32 | Reward disclosure là optional và example không dùng (`disclosureTitle`) — AdMob yêu cầu mô tả reward trước khi show; label nút là mức tối thiểu | `ad_screen.dart:141-144, 205-222`, `example/lib/main.dart:1115-1130` |
| m33 | `duration <= 0` bị reject nhưng caller báo "success" (`redeemVip` → `showVipSuccessDialog` + return `true`) | `vip_manager.dart:500-508, 657-661` |
| m34 | `ad_screen.dart:51/58/65` nội suy string eager mỗi lần host build, dù log level tắt (phần còn lại SDK dùng lazy closure) | như cột |
| m35 | `buildBanner()` không cho truyền `Key` ⇒ banner trong list đổi index bị tạo lại Element ⇒ native ad destroy + reload | `ad_screen.dart:52` |
| m36 | `onPaidEvent` không bị null trong `dispose()` của các wrap (chỉ null `fullScreenContentCallback`) ⇒ paid-event muộn vẫn `_emit` qua eventSink cũ | `gma_bridge.dart:250/283/319/361` |
| m37 | `AD_SERVICES_CONFIG` không document — không cần khai báo (đến từ AAR qua manifest merger) nhưng là nguồn build-failure kinh điển khi host có 2 SDK cùng khai báo (cần `tools:replace`) | grep README/doc/example: rỗng |
| m38 | `confetti: ^0.8.0` là runtime dependency của một ad SDK (chỉ dùng cho `VipRedeemScreen`) ⇒ mọi consumer inherit | `pubspec.yaml`, `vip_redeem_screen.dart:4` |

---

# INFO — những chỗ ĐÚNG, đã verify, đừng re-litigate

- **Mutex fullscreen phủ đủ 4 loại, không có race check-then-show.** `ad_manager.dart:1062-1072` gồm cả `rewardedInterstitialSlot` (`:1068`), loading buffer và `AdScreenRouteLogger.isDialogOnTop`. Mọi gate trong `show*` là **đồng bộ**, và adapter gọi `beginShow()` ngay dòng đầu trước bất kỳ `await` nào (`admob_adapter.dart:712/903/1063/1217`) ⇒ mutex đóng cùng microtask. Đường bypass rewarded có `await` thật nhưng **re-check** sau load (`:3406-3412`). `didRemove` được override đúng (`ad_route_observer.dart:82-89`) nên `_popupDepth` không kẹt.
- **Show-time freshness AdMob đúng cả 4 loại**: app-open 4h (`admob_adapter.dart:601`, check `:692-704`), 3 loại còn lại 1h (`:606`, check `:884-896, 1044-1056, 1197-1210`). Ad stale bị dispose + `markFailed` + caller nhận `false`/`skipped`, **không bị show**.
- **Gate `canRequestAds` kín 100% entry point**, kể cả đường bypass `AdManager` (`preloadBanner`/`preloadMrec` gọi trực tiếp ở `:2108-2109, 3965, 3972`) đều check `canReload()`, và `canReload` bao gồm `canRequestAds` (`:1987-1991`). Splash `bypassSafety: true` **cũng** bị chặn bởi gate consent (`:2815`, comment T03).
- **UMP fail-closed đã sửa đúng hướng** (đóng finding lịch sử): auto flow đóng gate trước adapter init (`:1919-1932`); **chỉ** `MissingPluginException` mở gate (`:1950-1967`), mọi exception khác giữ đóng (`:1968-1975`). MJ8/BL1 là bug **độc lập**, không phải re-open finding này.
- **Reward: không có double-grant ở cả 2 provider.** AdMob dùng cờ `fired` (`:1074`) + `earned` ⇒ robust với cả hai thứ tự callback. AppLovin lần thứ hai thấy `_rewardedDone == null` ⇒ không double. `vipAutoGrant` (`:3286-3293`) grant **mà không show ad nào** ⇒ không vi phạm reward policy.
- **Không có auto-click / auto-refresh <30s từ phía Dart.** Không `Timer.periodic` reload nào trong banner/mrec/native; `autoRefreshEnabled` chỉ bật/tắt theo route. Refresh interval do dashboard quyết định (phải tự set ≥30s ở đó — SDK không kiểm soát được).
- **Không rebuild storm.** `ad_screen.dart:52/59/66` trả `const BannerAdWidget()`/`const MrecAdWidget()`/`const NativeAdWidget()` ⇒ const canonicalize ⇒ `Element.updateChild` short-circuit hoàn toàn: không rebuild, không State mới, không load ad mới.
- **Không có `setState` sau dispose.** Cả 3 widget ad + `ad_screen.dart` dùng 100% `ValueNotifier`; mọi `addPostFrameCallback` đều có `if (!mounted) return`.
- **Ed25519 là verify thật, không so hash.** `cryptography ^2.9.0`, `signed_vip_key.dart:87` + `:162-168` (`_ed25519.verify(...)`), check độ dài public key = 32 (`:157`), key rotation list tolerant với key lỗi (`:147-170`). **Không có secret nào bị commit** (`tool/vip_keygen.dart` print ra stdout; test mint keypair ephemeral; example dùng demo keypair có cảnh báo rõ).
- **CRL verify đúng**: Ed25519 + domain separation (`AVP1|`, `AVP2|`, `CRL1|`), replay CRL cũ bị chặn bằng `issuedAt` monotonic ⇒ **MITM không forge được** (chỉ drop được — xem MJ13).
- **Trial = đúng 1 ngày ở release**: `FirstInstallVipGrace.auto` → `Duration(days: 1)`, debug 30s (`ad_config.dart:41-53`). Cấp đúng 1 lần; iOS chống bypass uninstall bằng Keychain `first_unlock` (`_first_install_guard.dart:77-79`), thứ tự write Keychain **trước** prefs flag đúng (`ad_manager.dart:1819-1832`). Android bypass được (clear data / no Auto Backup) — giới hạn đã disclose.
- **Provider switch sạch**: `_disposeAdapter()` (`:2679-2692`) remove listener + `await old.dispose()`; nhánh re-init-without-destroy (`:1650-1673`) cũng stop timer + stop connectivity watch + `_resetGuardState()`. AppLovin `dispose()` clear 4 native listener **trước tiên** với comment giải thích thứ tự.
- **Cold start đúng pattern AdMob**: resume đầu tiên luôn skip (`ad_safety_config.dart:534-544`); launch đầu tiên thực tế không có ad vì first-install grace 24h; splash App Open luôn có splash UI phía sau + hard cap 8s.
- **Remote config không mở được `dryRun` trong release** (`remote_ad_safety_provider.dart:68` luôn đi qua `applyDryRunReleaseGuard`).
- **Log sạch ở default release**: GAID chỉ log ở `verbose`, default release là `warning` ⇒ bị chặn. (Còn lại: host set `verbose` + `onLog` sink sẽ đẩy GAID sang Crashlytics — nên mask.)
- **Example đủ 7/7 điểm integration contract** (`main.dart:337` setNavigatorKey trước runApp, `:346` cả 2 observer, `:412-472` init trong splash, `:422` hard cap, `:414/415` markSplashActive + incrementSplashCount, `:482` showAdBuffer, `:491` bypassSafety, `:506` markSplashInactive, `:772+` AdScreen/AdScreenState). Chỗ lệch chỉ là m27, m29, m32 và nút ở MJ28.
- **iOS/Android config của example đủ**: `GADApplicationIdentifier`, `NSUserTrackingUsageDescription`, `SKAdNetworkItems` (~152 entry, superset AppLovin); Android `AD_ID` permission + `APPLICATION_ID` + `INTERNET`/`ACCESS_NETWORK_STATE`. Podfile iOS 13.0 ≥ floor cả 2 dep; `minSdk 24` ≥ floor mọi dep.
- **`applovin_adapter.dart:827` là branch platform DUY NHẤT** trong 5 file adapter/bridge, cố ý và có document. Không có `Platform.is*` nào trong `admob_adapter`/`gma_bridge`/`applovin_bridge`.

---

# Đối chiếu 3 audit độc lập round 5

| Finding | Claude (đây) | codex | agy |
|---|---|---|---|
| VIP redeem offline bị chặn | MJ10 | **M1** (Major, top) | **M1** (Major, duy nhất) |
| COPPA AppLovin một chiều | MJ7 | M2 | không nêu |
| UMP retry không mutex | MJ8 | M3 | không nêu |
| `SimpleEventBus.listen()` replay không guard | m1 | m1 | m1 |
| AVP2 bundle fail-open | m2 | m2 | không nêu |
| Example sai contract EventBus | m29 | m3 | không nêu |
| **UMP gate kẹt đóng (`error == null`)** | **BL1** | không phát hiện | không phát hiện |
| **Consent footgun fail-open** | **BL2** | không phát hiện | không phát hiện |
| **QA hashes always-on release** | **BL3** | Info (nêu là "cần quy trình") | Info (đánh giá "RẤT TỐT") |
| `tcfConsentString` luôn null | MJ2 | không phát hiện | không phát hiện |
| AppLovin privacy flags sau init | MJ1 | không phát hiện | không phát hiện |
| TFUA không tới GMA / rơi ở retry | MJ3, MJ4 | không phát hiện | đánh giá PASS |
| App Open late-callback giết ad mới | MJ15 | không phát hiện | đánh giá PASS |
| `showAdBuffer` throw ⇒ khoá fullscreen | MJ16 | không phát hiện | không phát hiện |
| AppLovin mất reward | MJ18 | không phát hiện | không phát hiện |
| Clock-forward poisoning | MJ9 | Info ("không bảo đảm tuyệt đối") | đánh giá "ĐÃ FIX HOÀN TOÀN" |
| App Open sau ad-click | MJ26 | không phát hiện | đánh giá PASS |
| `bypassSafety` bỏ fraud gate | MJ27 | không phát hiện | đánh giá PASS |
| **Verdict** | **KHÔNG (3 BL + 31 MJ)** | **KHÔNG** (5 điều kiện) | **CÓ, 1 điều kiện** |

**Nhận xét:** cả 3 agent độc lập đồng thuận MJ10 (VIP offline). Nhưng agy round 5 kết luận "0 Blocker, PRODUCTION-READY" trong khi cùng những file đó chứa BL1/BL2 và MJ15/MJ16/MJ18 — agy verify các fix *đã biết* rất kỹ nhưng không đi tìm lỗi *mới* trên các đường exception. Đây là lý do không nên lấy một audit làm bằng chứng đủ.

---

# Điều kiện ship

## Bắt buộc trước khi dùng vào production app (P0)

1. **BL1** — 1 dòng: `_umpAttemptFailed = result.error != null || umpInconclusive || !result.canRequestAds;` + test cho nhánh `error == null, canRequestAds == false`.
2. **BL2** — bỏ `!config.disableAppLovinCmpFlow` khỏi guard (hoặc gate theo provider) + test config `admob + autoRequestUmpConsent:false`.
3. **BL3** — gate `kQaTestDeviceHashes` sau `!isActuallyRelease()` **hoặc** thêm `mergeQaTestDevices` default `false`; document ở README.
4. **MJ10** — xoá connectivity gate ở `vip_manager.dart:685-689`; sửa `README.md:885-890` cho khớp `:1151`.
5. **MJ15, MJ16, MJ17, MJ19** — 4 fix trạng-thái-chết-vĩnh-viễn, mỗi cái ≤5 dòng. Đây là nhóm hoàn vốn cao nhất.
6. **MJ18** — cờ `earned`/`fired` cho AppLovin rewarded (mất reward = mất tiền của user, không phải của mình).
7. **MJ1, MJ5** — 2 fix consent 1-2 dòng, đều là legal exposure thật.
8. **MJ22** — cờ `_installed` + release chain xuống `previousOnError`. Không được để SDK ăn mất crash của production app.
9. **MJ29** — mở lại billing GitHub Actions, chạy đủ 4 job, **bắt buộc `sdk-integration-ios` xanh** cho commit sẽ ship. Đây là điều kiện không thoả hiệp được với một SDK claim dual-platform.
10. **MJ30** — `.pubignore` loại `doc/`, `test/`. Đang publish công khai bản đồ điểm yếu VIP của chính mình.

Ước lượng: ~60-80 dòng code + test, cộng thời gian CI/iOS verify.

## Nên fix trước hoặc ngay sau ship (P1)

MJ2 (bỏ hoặc sửa `tcfConsentString`), MJ3, MJ4 (TFUA — bắt buộc nếu app có audience under-age), MJ6, MJ7, MJ8, MJ9 (clock budget model), MJ12, MJ13, MJ14, MJ20, MJ21, MJ26, MJ27, MJ28.

## Nợ có deadline (P2)

MJ31 — plan nâng Flutter → GMA 9.x. Cần major version bump vì đổi `environment` floor. Đừng để tới lúc Google gửi thư.

## Quyết định về VIP zero-backend — nói thẳng

Với ràng buộc "không server/backend", các bypass MJ11/MJ12 và Android clear-data **không thể đóng được**, và attacker có root cũng patch được public key trong binary. Nên: đừng đầu tư thêm vào hardening state-local sau khi xong MJ9/MJ12/MJ13. Nếu doanh thu VIP đủ lớn để lo, câu trả lời là một endpoint verify (dù chỉ là một Cloud Function), không phải thêm checksum. Nếu không, chấp nhận và **document rõ trong README** mức bảo đảm thực tế là gì.

---

# MJ32 (finding mới, phát hiện khi verify vòng quyết định)

**SDK có thể hiện lại popup consent mỗi lần mở app cho user EEA đã đồng ý.**

**Evidence:** `lib/src/core/ump_consent.dart:129-146` — gate duy nhất trước khi `form.show()` là `isConsentFormAvailable()`. Theo doc của plugin (`google_mobile_ads-7.0.0/lib/src/ump/consent_information.dart:49-50`), hàm đó nghĩa là *"true if a ConsentForm is available"* — **không** phải "consent is required". Sau khi user đã đồng ý, form vẫn còn available (đó chính là cơ chế cho mục "Privacy Options" hoạt động — SDK cũng dùng nó ở `:234-259`).

Comment tại `:123-126` tự nêu giả định *"notRequired/obtained: form rarely available, no-op"* — đây là **giả định, không có bảo đảm nào**.

Plugin **đã có sẵn** API đúng: `ConsentForm.loadAndShowConsentFormIfRequired` (`google_mobile_ads-7.0.0/lib/src/ump/consent_form.dart:63-70`) — chính là hàm Google tạo ra để chỉ hiện form khi thật sự cần, và là cách làm khuyến nghị trong doc chính thức. SDK không dùng.

**Tại sao chưa ai phát hiện:** CI ép `AD_PROVIDER_ADMOB` và không có geo EEA thật; ở non-EEA thì UMP trả `notRequired` và không có form ⇒ đường này không bao giờ chạy trong test. 891 test Dart cũng không chạm tới hành vi native của UMP.

## MJ32 — ĐÃ KIỂM CHỨNG THỰC NGHIỆM: **CONFIRMED**, nâng lên Blocker

Chạy trên Pixel 7 Pro (`2B051FDH3006MU`), debug build, `debugGeography: debugGeographyEea` + `testIdentifiers: ['9005AD1E37B82BBBCF70A3B34C485083']`, provider AdMob.

**Lần 1** (dữ liệu app đã xoá sạch): `status: required` → form UMP thật hiện ra → bấm **Consent**.

**Lần 2** (cold restart, `am force-stop` + relaunch, **không** xoá dữ liệu):
```
[UmpConsent] consent status: obtained
[UmpConsent] ⚠️ consent form: consent form dismiss timed out after 20s
[UmpConsent] ✅ done canRequestAds=true status=obtained formShown=true
```
Screenshot xác nhận form hiện lại nguyên vẹn trên màn hình dù `status == obtained`.

⇒ **User EEA bị hiện popup consent mỗi lần mở app, vĩnh viễn.** Không phải rủi ro lý thuyết. Đây là vi phạm nguyên tắc không nag của UMP/GDPR và là lỗi UX nghiêm trọng — **nâng từ finding cần xác minh lên BLOCKER**.

**Quyết định:** giữ khối load/show thủ công, thêm điều kiện `status == ConsentStatus.required` trước khi `form.show()` (giữ được tín hiệu `formShown` mà BL1 và m11 phụ thuộc). Gộp vào commit 1.

---

# MJ33 (finding mới, phát hiện trong lúc kiểm chứng MJ32)

**Timeout chờ đóng form consent là 20 giây — ngắn hơn thời gian đọc thực tế của một form GDPR.**

**Evidence:** `lib/src/core/ump_consent.dart:153-156`.

Form UMP thật liệt kê **206 đối tác** + mục "Learn more" có thể mở rộng. Quan sát trực tiếp trong lần chạy thứ nhất: người dùng bấm chậm hơn 20s ⇒ SDK bỏ cuộc **trong khi form vẫn đang hiển thị trên màn hình**, trả `error='consent form dismiss timed out after 20s'` và chốt `canRequestAds=false, status=required`, tức quyết định gate được đưa ra trước khi user kịp trả lời.

Timeout này tồn tại vì lý do chính đáng (comment `:147-152`: iOS Simulator từng treo vĩnh viễn khi không có ai tap). Nhưng 20s áp cho **người dùng thật** là quá ngắn.

**Tương tác với BL1:** sau bản sửa BL1, `error != null` ⇒ `_umpAttemptFailed = true` ⇒ retry — và nếu MJ32 chưa sửa thì retry sẽ hiện form **lần nữa** trong lúc form đầu còn trên màn hình.

**Minimum fix:** nâng timeout cho đường có form thật lên mức hợp với người đọc (đề xuất 180s), giữ mức ngắn chỉ cho môi trường test; hoặc bỏ timeout khi form đã thực sự `show()` thành công và chỉ giữ timeout cho bước `loadConsentForm`.

---

# Trạng thái triển khai — Commit 1 (2026-08-22)

**Đã fix + verify: BL1, m11, MJ8, MJ32, MJ33, và phần retry của MJ3.**

Gate: `flutter analyze` 0 issues, `flutter test` **897/897 pass** (thêm 6 test mới trong `test/ump_consent_round5_test.dart`).

**Verify trên hardware thật** (Pixel 7 Pro, `debugGeography: debugGeographyEea`, `testIdentifiers: ['9005AD1E37B82BBBCF70A3B34C485083']`, provider AdMob) — A/B trên cùng thiết bị, cùng state:

| Kịch bản | Trước fix | Sau fix |
|---|---|---|
| Cold restart, consent đã cấp | `status=obtained formShown=true` + form hiện lại trên màn hình | `consent form not required (status=obtained) — skip`, `formShown=false`, App Open ad chạy bình thường |
| Fresh install, geo EEA | form hiện | form **vẫn hiện** (đường pháp lý không bị phá) |
| Để form mở 59 giây | `consent form dismiss timed out after 20s` khi form còn trên màn hình | không có timeout; nhận đúng lựa chọn của user |

Ghi chú: sau khi bấm "Do not consent", UMP trả `canRequestAds=true status=obtained` — đúng, vì vẫn được serve ad non-personalized. Nên nhánh m11 không bị kích hoạt ở ca này; logic cờ được phủ bằng unit test.

Ngoài ra `MJ3` mới xong **một nửa** (retry replay params). Nửa còn lại — set `tagForUnderAgeOfConsent` lên `RequestConfiguration` của GMA (MJ4) — vẫn thuộc commit 2.

---

# Trạng thái triển khai — Commit 2 (2026-08-22)

**Đã fix: BL2, MJ1, MJ2, MJ4, MJ5, MJ6, MJ7, m5, m6, m7, m8, m9, m10, m12, m13 (phần timeout ATT + Keychain).**

Gate: `flutter analyze` 0 issues, `flutter test` **904/904 pass**.

**Verify trên hardware thật** (Pixel 7 Pro, EEA debug geography): MJ2 trả về chuỗi TCF v2 thật `CQpWQEAQpWQEAEsACBENCtFoAP_g…` đọc từ kho mặc định của app — trước fix luôn `null`. `usPrivacyOptedOut`/`gpp` trả `null` đúng như hợp đồng (user EEA giả lập, không có CMP nào ghi tín hiệu US).

⚠️ **Nhánh iOS của MJ2/m10 chưa được chạy trên thiết bị** — theo đúng logic của plugin nhưng chưa verify, xem MJ29.

## Ba test cũ phải sửa vì chúng mã hoá chính hành vi sai

Đáng ghi lại, vì đây là lý do các vòng audit trước không bắt được:

1. `consentFootgunWarning (F4) disableAppLovinCmpFlow:false → no warning` — khẳng định cấu hình AdMob fail-open là **đúng**. Nay tách thành 2 test: AppLovin thì không cảnh báo, AdMob thì phải cảnh báo.
2. `shouldDeferGaidFetch iOS + ATT status unreadable (null) → do not defer` — tức chấp nhận việc SDK tự bật popup theo dõi của Apple khi không đọc được trạng thái.
3. `tcfConsentString reads the IABTCF_TCString...` — dùng `setMockInitialValues`, tức **trả lời một câu hỏi mà kho thật không bao giờ nhận được**. Test này pass suốt 4 vòng audit trong khi code không thể chạy đúng trên bất kỳ thiết bị nào. Nay dùng `InMemorySharedPreferencesAsync` — chính platform interface mà production dùng.

Bài học: một mock trả lời sai tầng thì tệ hơn không có test.

## Phát sinh trong lúc triển khai

- **MJ33 có tác dụng phụ với test tự động**: nâng timeout lên 180s làm một lần chạy integration trên thiết bị mất 3,5 phút (harness không tap được dialog native nên đợi hết). Đã thêm `debugFormDismissTimeoutOverride` cho harness.
- **m12 làm hỏng 3 test retry-timer** theo cách không hiển nhiên: re-attempt khiến connectivity checker chạy thật trong `flutter test`, mọi HTTP probe trả 400 nên kết luận offline, `canReload()` false và mọi refill sau đó im lặng không làm gì. Đã dùng seam `debugConnectivityReady` sẵn có.
- **MJ7 gần như sai**: `setConsent` gán `_consent = consent` ngay dòng đầu, nên phép so sánh "cờ có đổi chiều không" luôn false. Phải chụp giá trị cũ trước khi gán.
- **MJ2 cần khai báo `shared_preferences_android`** — package đã nằm sẵn trong mọi build Android (nó *là* phần thực thi của `shared_preferences`), nhưng lớp `SharedPreferencesAsyncAndroidOptions` không được re-export. Đây là API tầng thực thi, không phải API công khai ⇒ nợ kỹ thuật: nâng `shared_preferences` lớn có thể phải sửa lại.

---

# Smoke test trên thiết bị thật — sau commit 3 (2026-08-22)

Samsung SM-A115F (`R9JN61LDLFJ`, nằm trong `kQaTestDeviceHashes` nên chắc chắn ra test ad), provider AdMob, debug build, xoá sạch dữ liệu app trước khi chạy.

| Bề mặt | Kết quả |
|---|---|
| UMP ngoài EEA | `status=notRequired` → `consent form not required — skip`, `formShown=false` (MJ32 không phá đường non-EEA) |
| IAB strings | `tcf=null usPrivacyOptedOut=null gpp=null` — đúng: không CMP nào ghi gì ở non-EEA |
| First-install VIP grace | cấp 30s (debug), `loadAppOpen skipped — VIP member` đúng |
| Test device | `0 from host config + 8 QA fleet (always on) = 8 total` |
| Banner ×2 | load độc lập, cùng trang; watchdog 30s (MJ20) **không** fire oan |
| Route pause/resume | push màn thứ 2 → banner mới load; pop → dispose sạch |
| Interstitial | `showAdBuffer` trọn vòng show → dismiss → `onComplete()` (MJ16 giữ nguyên happy path) |
| App Open on resume | resume 1: skip cold-start one-shot đúng; resume 2: `✅ all gates passed` → shown → `👋 dismissed` → reload (MJ15 + MJ24) |
| Rewarded | `🏆 type=coins amount=10`, `onEarnedReward: result=true` |

Quét toàn bộ log phiên: **0** `EXCEPTION`/`Unhandled`, **0** lỗi "was disposed", **0** `setState() called after`, **0** lần watchdog fire.

Lưu ý: smoke test này chạy đường **AdMob + non-EEA**. Đường AppLovin và đường EEA đã verify riêng ở các mục MJ32/MJ2 phía trên. iOS vẫn chưa chạy (MJ29).

---

# Review độc lập của chính đợt fix (2026-08-22) — điểm 6/10

Một reviewer độc lập được chỉ vào diff round 5 **trước khi ship**. Kết quả: **3 trong số các fix flagship không hoạt động trên đường đi chính của chúng**. Tôi tự chấm 8/10 dựa trên "905 test xanh + smoke test sạch" — đúng kiểu lập luận mà chính round này đáng lẽ đã dạy tôi đừng tin.

| Finding | Bản chất | Đã xử lý |
|---|---|---|
| **B1** MJ6 là code chết | `setConsent` gán `_consent` trước, `ConsentManager` notify **đồng bộ** ⇒ listener so giá trị mới với chính nó | So với `_lastAppliedConsent` (thứ đã thực sự apply xuống adapter) — độc lập với thứ tự gán. Test verify **đỏ** khi hoàn nguyên |
| **M1** nửa inline của MJ6 cũng no-op | `initRevision` không rebuild banner đang có ad (listener chỉ act khi `!_allowed`) | Thêm `personalisationRevision`; 3 widget drop instance rồi reload |
| **M2** MJ7 không tới được | early-return `!isInitialised` nằm **trên** khối MJ7, mà child-directed abort chính là thứ làm nó uninitialised | Đưa khối lên trước; `_lastKnownConfig` sống qua teardown |
| **M3** MJ20 chỉ đổi nhãn slot | `loadBanner` early-return khi map còn key ⇒ ad chết chặn mọi load sau | `onTimeout` hook dọn map |
| **M6** mutex không deadline | biến hang tạm thời thành khoá vĩnh viễn — **tệ hơn BL1 vừa sửa**, và đã publish trong 2.3.1 | cap 240s + identity guard khi nhả lock |
| **M7** backstop mở form thứ 2 | `Future.timeout` không đóng form native | cờ `_umpFormAbandoned` |
| **M4/m9** | `autoShowConsentDialog` default-true thành no-op im lặng | ghi rõ trong dartdoc |
| m4, m5, m7 | ownership dialog, cùng bug ở `show()`, cap version | đã sửa |
| **m1** replay không guard | `SimpleEventBus.listen` replay `_lastEvent` ngoài try/catch trong khi `fire` có guard ⇒ subscriber ném lỗi làm văng ngay tại `listen()`, mà caller theo hợp đồng tích hợp là splash của app | bọc try/catch + `test/event_bus_test.dart` (3/4 test đỏ khi gỡ fix) |

> **Ghi chú trung thực:** dòng trên trước đây gộp `m1` vào danh sách "đã sửa" — **sai**. Code sản phẩm chưa hề sửa và không có test nào. QC agy vòng 5 phát hiện. Đây đúng loại lỗi mà cả vòng audit này đi chữa: tuyên bố vượt quá bằng chứng.

**Một khuyến nghị của reviewer bị TỪ CHỐI:** reset `_connectivityReady` khi teardown. `connectivity_refill_test.dart` ghi rõ đây là state **cấp process** và assert `destroy()` **không được** reset, nếu không mỗi lần re-init lại mở cửa sổ đọc im lặng. Khoảng trống thật hẹp hơn (subscription bị cancel) đã ghi trong code kèm lý do vì sao đóng nó phải trả bằng seam test-only.

## Test không trung thực — nguyên nhân gốc để B1/M2/M3 sống sót qua 905 test

- Test MJ15 gọi một **debug seam viết lại chính 2 dòng cần test** ⇒ xoá fix khỏi callback thật vẫn xanh. Đã thay bằng test đi qua `GmaShowCallbacks` thật, và **verify đỏ** khi hoàn nguyên.
- Hai fake capture dữ liệu để "assert được thứ tự" (`initOrder` cho MJ1, `capturedCoppaTag`/`capturedTfuaTag` cho m8) mà **không test nào assert**. Giờ có.
- Thêm: regression B1, canary compile-time cho `shared_preferences_android`.

# iOS đã verify trên simulator (2026-08-22)

Ghi `IABTCF_TCString` + `IABUSPrivacy_String` vào NSUserDefaults của simulator dưới bundle id thật rồi đọc lại qua SDK:

```
IAB: tcf=CIOSVERIFY_tcf_v2 usPrivacyOptedOut=true gpp=null
```

⇒ nhánh iOS của MJ2/m10 **hoạt động thật**. Điểm trừ "code chưa verify" đã đóng cho cả hai nền tảng.

Lần thử đầu trả `null` vì tôi ghi vào applicationId của Android (`com.roy.admobwrapper`) thay vì bundle id iOS (`com.example.adSdkExample`) — đáng ghi lại, vì `null` ở đó **trông giống hệt** một đường đọc bị hỏng thật.

---

# Quyết định Round 5 (chốt với product owner, 2026-08-22)

## Hai mục được xác định là TÍNH NĂNG CÓ CHỦ Ý, không phải bug

Ghi rõ ở đây để các vòng audit sau (và các agent độc lập) **không flag lại**:

1. **`redeemSignedKey` yêu cầu có mạng** (`vip_manager.dart:685-689`) — **product gate có chủ ý**, không phải giới hạn kỹ thuật. Ed25519 verify vốn chạy offline được; gate này là quyết định sản phẩm. **Việc cần làm:** sửa `README.md:1151` bỏ chữ "fully offline" cho khớp với `:885-890`, và làm rõ comment tại `vip_manager.dart:673-676` là *deliberate product gate — do not "fix"*. Ba agent độc lập (claude/codex/agy) đều đã flag mục này ở round 4 và round 5 → dấu hiệu chú thích hiện tại chưa đủ rõ.
2. **`kQaTestDeviceHashes` always-on** (`ad_config.dart:218-227`) — **tính năng có chủ ý**: QA trên hardware thật không bao giờ được tính thành impression/click thật, kể cả ở release build. **Việc cần làm:** document ở README (hiện chỉ có ở `CHANGELOG.md:11-12`) và ghi rõ trong comment rằng đây là chủ ý, kèm đánh đổi đã biết (8 hash public trên pub.dev; máy trong danh sách không tạo doanh thu).

## Bảng quyết định

| # | Vấn đề | Quyết định |
|---|---|---|
| BL1 | UMP gate kẹt đóng cả session | Sửa: `_umpAttemptFailed = error != null \|\| umpInconclusive \|\| !canRequestAds` |
| BL2 | Consent-footgun gate fail-open | Sửa: chỉ áp dụng `disableAppLovinCmpFlow` khi provider là AppLovin |
| BL3 | QA test-device hashes | **Tính năng** — giữ nguyên, document README |
| MJ10 | VIP redeem chặn offline | **Tính năng** — giữ gate, sửa README cho khớp |
| m11 | Retry popup vô hạn | Sửa cả hai: cap 5 lần + không retry nếu `formShown` |
| MJ1 | AppLovin nhận privacy flags sau init | Truyền `AdConsent` vào `adapter.initialize()` như param |
| MJ2 | `tcfConsentString` luôn null | Sửa đọc đúng native store (cần verify trên máy thật cả 2 OS) |
| MJ3+MJ4 | TFUA rơi ở retry + không tới GMA | Sửa cả hai |
| MJ5 | `_consent` stale xoá CCPA/COPPA | Cả hai: đồng bộ trong listener + đọc qua ConsentManager ở 2 call site |
| MJ6 | Ad đã cache vẫn show sau khi rút quyền | Huỷ ad đã tải khi quyền bị rút |
| MJ7 | COPPA AppLovin một chiều | Khởi động lại AppLovin khi cờ đổi chiều |
| MJ8 | UMP chạy chồng lượt | Chỉ cho 1 lượt xin phép tại một thời điểm |
| MJ9 | Clock-forward poisoning | **Đổi sang mô hình đếm thời lượng còn lại** (việc lớn nhất) |
| MJ11 | Fallback store giả mạo được | Chặn trần 90 ngày cho dữ liệu từ nơi dự phòng |
| MJ12 | iOS: mốc chống rollback yếu hơn entitlement | Lưu mốc vào cùng nơi an toàn với dữ liệu VIP |
| MJ13+MJ14 | CRL không revoke được + không timeout | Sửa cả hai |
| MJ15 | App Open callback muộn giết ad mới | Identity guard `identical(_appOpenAd, ad)` ở mọi nhánh |
| MJ16 | `showAdBuffer` throw ⇒ khoá fullscreen | Cả hai: set cờ sau khi push + try/catch gọi `onComplete()` |
| MJ17 | `dismiss()` thiếu `_generation++` | `_generation++` + call site rewarded chỉ dismiss khi tự show |
| MJ18 | AppLovin mất reward | Bê cặp cờ `earned`/`fired` của AdMob sang |
| MJ19 | Adapter orphan khi init fail | `await adapter.dispose()` trước `return` |
| MJ20 | Banner/MREC/native kẹt "đang tải" | Cả hai: watchdog 30s + cho `_retryRefillAds` quét 3 loại này |
| MJ21 | Race dispose-during-await | Mở rộng tombstone-set của native sang banner + MREC |
| MJ22 | Crash guard ăn mất crash của host | Cờ `_installed` + release chain xuống `previousOnError` |
| MJ23 | Slot kẹt `showing` | Bổ sung loại còn thiếu vào `_recoverSlots` (2 dòng) |
| MJ24+MJ25 | Watchdog arm sau `await` + catch không dispose | Sửa cả hai |
| MJ26 | App Open sau khi user click ad | Ghi nhậy thời điểm click, chặn 30s sau đó |
| MJ27 | `bypassSafety` bỏ luôn fraud gate | Tách fraud-check ra khỏi caps; fraud-check không ai được miễn |
| MJ28 | `resetSession()` xoá fraud state | Tách: chỉ reset counter phiên; sửa nút ở example |
| MJ29 | CI chết, iOS chưa verify | **Ship dựa trên 891 test + Android tay** (chấp nhận rủi ro có chủ ý) |
| MJ30 | `doc/` publish lên pub.dev | `.pubignore` loại `doc/` (trừ screenshots) + `test/` |
| MJ31 | GMA 7 vs 9.1 | Lên kế hoạch nâng, chưa làm đợt này |
| MJ32 | Popup consent có thể hiện lại mỗi launch | Kiểm chứng thật bằng `debugGeography` trước, rồi quyết |
| Minor nhóm 1 | Rò rỉ bộ nhớ nhỏ | Sửa hết 7 mục |
| Minor nhóm 2 | Độ tươi + đồng hồ | Sửa 3 mục phía AdMob, giữ nguyên AppLovin (đúng thiết kế) |
| Minor nhóm 3 | Consent + ổn định nhỏ | Sửa hết 9 mục |
| Minor nhóm 4 | Tài liệu + app mẫu + VIP nhỏ | Sửa tài liệu + app mẫu + 2 mục VIP; **bỏ** nhóm hiệu năng |

## Ghi chú phụ thuộc khi triển khai

- **m11 phụ thuộc BL1** — phải làm cùng lượt, nếu không bản sửa BL1 sẽ tạo ra retry vô hạn.
- **MJ8 phụ thuộc BL1** — BL1 làm đường retry chạy thường xuyên hơn ⇒ xác suất chạy chồng tăng.
- **MJ32 chồng lấn MJ3 và m11** — cả ba đụng cùng khối `ump_consent.dart` / `requestUmpConsent`; quyết MJ32 trước khi sửa hai mục kia, hoặc làm cùng lượt.
- **MJ2 và mục "đọc tín hiệu riêng tư các bạng Mỹ" (Minor 3) cùng một loại khó** — đều phải đọc đúng native store, khác nhau giữa Android và iOS, và **không xác minh được bằng test Dart**. Với quyết định MJ29 (bỏ kiểm thử iOS), hai mục này là phần rủi ro cao nhất trong cả đợt: nên verify tay trên máy thật, ít nhất Android.
- **MJ9 là redesign, không phải patch** — nên làm thành commit riêng, có bước chuyển đổi dữ liệu cho user đang giữ VIP.

---

# Lịch sử ngắn

- **Đóng trong round 5** (tự verify, không re-litigate): UMP "mọi exception đều fail-open"; stale GAID qua destroy/re-init; banner/MREC/native không phản ứng gate consent; AdMob banner/MREC reload xong vẫn hidden; eCPM=0 nudge; exception một listener chặn listener khác trong `fire()`; VIP clock-**rollback** (chiều lùi — chiều tiến là MJ9, bug khác); mutex fullscreen thiếu rewarded-interstitial; multi-instance singleton conflict.
- **Mở từ round 4 sang round 5**: MJ10 (VIP offline) — 3 agent độc lập cùng re-confirm.
- **Mới ở round 5**: BL1, BL2, BL3, MJ1-MJ9, MJ11-MJ31 và phần lớn danh sách Minor.
- **Không đóng được bằng client-only**: Android clear-data reset ledger/trial; trusted clock; chống repack/thay public key.

---

# BÀN GIAO — trạng thái cuối phiên 2026-08-22

**Gate:** `flutter analyze` sạch, `flutter test` **922/922**. 9 commit local, **chưa push** (điểm 5/10, dưới ngưỡng >8 mà product owner đặt). pub.dev: **2.3.1**.

## Điểm do 2 reviewer độc lập chấm, KHÔNG phải tự chấm

Tôi tự chấm 8/10. Reviewer A: **5/10**. Reviewer B: **5/10**. Cả hai đều tìm ra lỗi thật trong đúng phần tôi vừa tuyên bố đã sửa. Đừng tin bản tự chấm.

Thí nghiệm quyết định của reviewer B: **revert đồng thời 20/24 fix mà suite vẫn xanh hết** ⇒ con số test không nói gì về phần lớn diff.

## Fix ĐÃ qua revert-để-thấy-đỏ (11)

MJ32, MJ15, B1, M1-counter, MJ1, m8, MJ23, MJ16, MJ17, MJ25 (×4 nhánh), MJ2 (verify thiết bị cả 2 nền tảng).

## Fix CHƯA kiểm chứng (13) — việc tiếp theo

MJ24, MJ19, MJ20, M2, M3-onTimeout, M6 mutex, M7, m1, m4, m5, MJ21, m9, M1-nửa-widget (test hiện chỉ assert bộ đếm, không assert 3 listener thật nơi ad bị drop).

## Finding còn MỞ của reviewer

- **M-3 (Major, reviewer A)** — `_umpFormAbandoned` khoá backstop cả phiên. **Đây là lỗi tôi tự tạo**: form quá 180s ⇒ user trả lời muộn vẫn mất hết ad cả phiên, trước khi tôi sửa thì backstop retry và mở cổng được. Cân nhắc hoàn nguyên nếu không sửa đúng.
- **M-4** — hard cap App Open so field với chính nó ⇒ guard vô nghĩa. Fix (capture `ad` khi arm) làm đỏ test MJ15 vì lý do chưa truy được; đã ghi chú tại chỗ trong code.
- **M-2 reviewer B** — `iab_storage_canary_test` là tautology: tự tạo options rồi assert lại chính nó, không kiểm production có dùng options đó. Xoá `fileName` khỏi production vẫn xanh.
- m-6 `_lastKnownConfig` có thể stale · m-11 pubspec bỏ cap trên nhưng canary không nổ trước consumer vì `pubspec.lock` ghim.

## Nợ khác

9 mục rò rỉ lifecycle · 12 mục tài liệu/app mẫu · MJ9 redesign VIP (mục duy nhất lợi dụng được **không cần root**; cần chuyển đổi dữ liệu, làm sai là mất VIP người đã mua) · MJ31 nâng GMA 7→9 · **2.3.1 trên pub.dev vẫn chứa M6**.

## Ba bài học quy trình — đắt nhất trong phiên

1. **Revert-để-thấy-đỏ là bắt buộc.** Nó bắt được: test MJ15 gọi debug seam viết lại chính code cần test; 2 fake capture dữ liệu mà không ai assert; và một lần **test của tôi sai chứ không phải code** (2 dialog cùng 500ms).
2. **Đừng commit khi agent khác đang sửa working tree.** `606cfe7` đã `git add` theo path và nuốt bản hoàn nguyên tạm của reviewer, xoá mất 4/6 chỗ của fix MJ15 — commit trong lúc test cho nó đang đỏ. Commit trước khi delegate, hoặc đọc diff đã stage.
3. **Cùng một cái bẫy vấp 3 lần.** "So sánh với biến đã bị ghi đè": nhận ra cho cờ COPPA, rồi vấp cho `hasUserConsent`, rồi vấp lần nữa vì `_lastAppliedConsent` không được seed. Khi sửa loại lỗi này, phải grep **mọi** nơi ghi biến đó, không chỉ nơi đọc.

## Đường đi đã chốt

Mỗi phiên mới làm **1 nhóm**, kết phiên bằng **1 reviewer độc lập**. Ưu tiên: (1) test cho 13 fix còn lại, (2) M-3, (3) 9 mục rò rỉ, (4) MJ9 — để sau khi CI sống (tháng sau).

---

# BÀN GIAO — tiếp nối phiên 2026-08-22 (cùng ngày, agent khác)

**Gate:** `flutter analyze` sạch, `flutter test` **934/934** (+12 so với 922 baseline đầu phiên). 8 commit mới, **chưa push**.

## Đã làm — VIỆC 1 (test cho fix chưa kiểm chứng)

Tất cả đều qua **revert-để-thấy-đỏ** (hoàn nguyên đúng dòng fix, chạy đúng test, xác nhận đỏ, phục hồi, xác nhận xanh lại) trước khi commit — ghi trong từng commit message:

- **MJ19** — `adapter.dispose()` khi init fail. Test: `ad_manager_init_dispose_test.dart`. Thêm seam `AdManager.debugAdapterFactory`.
- **MJ20 + M3** — watchdog 30s banner/mrec/native + dọn cache ad chết. Test: `admob_widget_load_watchdog_test.dart` (fakeAsync, cả 3 loại). Thêm seam `debugNativeListenerFor`.
- **MJ21** — race dispose-during-await banner (identical-slot guard). Cùng file trên.
- **M2** — khối COPPA re-init phải nằm TRƯỚC early-return `!isInitialised`. Test: `ad_manager_coppa_recover_test.dart`, dùng adapter giả mô phỏng đúng hành vi từ chối init của AppLovin.
- **M6** — mutex `_umpInFlight` timeout 240s tự chữa. Test: `ump_consent_round5_test.dart` (fakeAsync, hang thật ở `MobileAds#updateRequestConfiguration`). **Phần identity-guard (`identical(_umpInFlight, started)`) KHÔNG viết được test tin cậy** — cần `_resetGuardState()` thật (chỉ gọi được qua `initialize()` đầy đủ), và `initialize()` đầy đủ không chạy xong bên trong `fakeAsync` (một số await không tiến qua được bằng pump microtask/timer thường); bản real-time thì đụng timer VIP/retry thật của SDK gây flaky. Đã thử và bỏ — xem comment trong commit.
- **m5** — `AdLoadingDialog.show()` (không phải `showAdBuffer`) phải raise `_isShowing` sau khi route tồn tại. Test: `ad_loading_dialog_test.dart`.
- **M1 (nửa còn lại, banner)** — widget listener thật trong `banner_ad_widget.dart` phải dispose instance khi `personalisationRevision` đổi, không chỉ đếm counter. Test: `banner_ad_widget_test.dart`. **mrec/native chưa làm** — cùng pattern, cùng fix, chỉ khác file.
- **m4** — đã đọc kỹ, **không viết test**: `busyR` (`_fullscreenBusyReason`, kiểm `AdLoadingDialog.isShowing`) đã chặn hoàn toàn việc vào nhánh này khi có dialog người khác đang hiện, và toàn bộ đường từ đó tới `AdLoadingDialog.show(ctx)` là đồng bộ (không `await`) nên không có cách nào interleave. Kết luận: fix đúng về mặt phòng thủ nhưng **không reachable qua bất kỳ đường thật nào hiện tại** — cùng loại với M-4 (xem dưới), khác ở chỗ M-4 tôi vẫn viết được test bằng debug seam vì nó chỉ cần 1 object field bị ghi đè, còn m4 cần bypass được cả một gate ở tầng trên mà không có seam hợp lý để làm vậy mà không trùng lặp chính logic cần test.

## Đã làm — VIỆC 2 (3 finding còn mở) — XONG CẢ 3

- **M-3** (đúng như audit gọi tên trùng — cũng chính là **M7** trong bảng fix-list) — `_umpFormAbandoned` khoá backstop cả phiên là **lỗi thật**. Đã chọn hướng (a): thêm `recheckUmpConsentStatus()` (đọc local, không form, không network) trong `ump_consent.dart`; cả backstop lẫn đường reconnect giờ gọi recheck thay vì bỏ qua hoàn toàn khi `_umpFormAbandoned`. Refactor: tách phần đuôi chung của `_requestUmpConsent`/`_recheckAbandonedUmpForm` ra `_applyUmpConsentResult` để 2 đường không lệch nhau logic. Điều kiện clear cờ đúng là `status != required` (không phải `!umpInconclusive` — một form chưa trả lời đọc lại vẫn `error=null, status=required`, tức "conclusive" nhưng chưa resolve). Test: `ump_consent_round5_test.dart`, group `M-3`. Reconnect trước đây **không** check cờ này — đã fix nốt cho nhất quán với backstop.
- **M-4** — `_armAppOpenWatchdog`'s timer đọc `_appOpenAd` tươi rồi so với chính nó ⇒ vô nghĩa. Đã truy ra tại sao thử trước làm đỏ MJ15 nhưng **lần này áp fix (truyền `ad` làm tham số, capture tại thời điểm arm) không làm đỏ bất kỳ test nào** — đã chạy full suite xác nhận. Không reachable qua đường thật hiện tại (đã phân tích: state-guard + identity check `_appOpenDismiss != captured` đã đủ bảo vệ trong mọi trường hợp hiện có), nên viết test bằng seam mới `debugReplaceAppOpenAdUnsafe` để phòng hồi quy tương lai. Test: `admob_behavioral_test.dart`, group `M-4`.
- **Canary tautology** — `iab_storage_canary_test.dart` tự tạo options rồi assert chính nó. Đã tách `IabStorage.androidOptionsFor(fileName)` (`@visibleForTesting`, sản xuất chính là hàm `_open()` gọi), test giờ gọi hàm production thật. Revert-để-thấy-đỏ: xoá `fileName` khỏi lời gọi ⇒ cả 3 test trong file đỏ.

## CHƯA làm (do hết ngân sách phiên, không phải do khó/không biết cách)

- **m4** — xem phân tích trên, không unreachable-nhưng-untestable, mà **unreachable qua production path hiện tại**; không viết test giả tạo.
- **M1 cho mrec/native** — cùng pattern với banner, chưa làm.
> ⚠️ **HAI DÒNG NGAY DƯỚI ĐÃ LỖI THỜI — đọc mục "BÀN GIAO — VIỆC 3" bên dưới thay thế.** VIỆC 3 đã **XONG** (6 fix + 3 mục xác định không phải bug, commit `ea8b3cc`…`08b2087`) và VIỆC 4 / MJ9 đã có **quyết định không sửa kèm lý do** (`8021d82`, xem § MJ9 ở trên). Giữ lại nguyên văn để thấy trạng thái lúc đó, không phải để tin là hiện trạng.

- **VIỆC 3 — 9 mục rò rỉ lifecycle** — CHƯA BẮT ĐẦU *(lỗi thời, xem cảnh báo trên)*. Danh sách ứng viên (từ bảng MINOR có sẵn, chưa verify lại `file:line` hiện tại): m21 (`_disposedNativeKeys` phình vô hạn), m22 (`_destroyWidgetAdViewWhenDetached` Future.delayed không cancel), m36 (`onPaidEvent` không null trong dispose), m24 (`BannerListenables` rò không có slot), m16 (`isAdFresh` wall-clock), m15 (expiry tính là failure, đầu độc backoff — `beginReload()` là API đúng), m18 (`canShowInterstitial/canShowRewardedAd` không check freshness), có thể thêm m19/m20/m23/m25 tuỳ agent kế tiếp chọn đủ 9. **Việc đầu tiên của phiên sau: đọc lại các dòng này trong code hiện tại (đã trải qua nhiều fix từ phiên này, số dòng chắc chắn lệch) trước khi tin bất kỳ `file:line` nào ở trên.**
- **VIỆC 4 — MJ9 (VIP clock-forward poisoning, redesign)** — CHƯA BẮT ĐẦU. Đây là mục **rủi ro cao nhất** trong toàn bộ audit (dữ liệu thật của user đã mua VIP, sai là mất không hoàn nguyên được). Task gốc yêu cầu: nếu không chắc, DỪNG và ghi lý do thay vì đoán. Quyết định của phiên này: **dừng, không đoán**, để lại cho phiên có đủ ngân sách thời gian làm cẩn thận theo đúng yêu cầu (commit riêng, test migration + test lỗ hổng, không trộn việc khác).

## Bài học phiên này

1. **M-4 và m4 cùng một lớp bug** ("so sánh/gate với chính field vừa đọc, hoặc gate đã đủ mạnh ở tầng trên khiến fix bên dưới không reachable") — nhưng chỉ M-4 viết được test không giả tạo (seam ghi đè 1 field, không trùng logic). m4 cần bypass một gate nhiều điều kiện; không có cách làm vậy mà không tự viết lại một phần logic gate đó — nên bỏ, ghi lại lý do thay vì ép một test không phản ánh thực tế.
2. **fakeAsync không tương thích với `AdManager().initialize()` đầy đủ.** Nhiều lần thử wrap toàn bộ init flow (VipManager, FirstInstallGuard, GAID...) trong `fakeAsync` bị treo ở giữa chừng dù không có lỗi rõ ràng. Cách né: bootstrap thật (real async, ngoài `fakeAsync`) trước, chỉ đưa đúng phần cần kiểm soát thời gian ảo (ví dụ `requestUmpConsent()`) vào trong `fakeAsync`.
3. **`config.disableAppLovinCmpFlow` mặc định `true`** — nghĩa là mặc định consentFootgunWarning() coi AppLovin KHÔNG có CMP che phủ. Test dùng AppLovin provider mà không tắt `autoRequestUmpConsent` phải set `disableAppLovinCmpFlow: false` hoặc gọi `requestUmpConsent()` trước, nếu không assert(false) sẽ nổ mỗi lần `initialize()` chạy.

---

# BÀN GIAO — VIỆC 3 (rò rỉ lifecycle), phiên 2026-08-22 (agent thứ ba cùng ngày)

**Gate:** `flutter analyze` sạch, `flutter test` **951/951** (+12 so với 939 đầu phiên). 6 commit mới, **chưa push, chưa publish**. CI không chạm (vẫn chết vì billing).

Mọi `file:line` trong bảng MINOR ở trên đã được **định vị lại trong code hiện tại** trước khi sửa — nhiều dòng đã lệch.

## Đã fix (6) — mỗi mục 1 commit, mỗi mục đều qua revert-để-thấy-đỏ

| # | Fix | Test | Dòng đỏ quan sát được |
|---|---|---|---|
| m15 | Expiry lúc show ghi nhận bằng `markFailed()` (⇒ `consecutiveFailures++`, `lastErrorAt=now`) làm refill mà `AdManager` bắn ra ngay trong callback `onDone/onDismiss` đó bị chặn bởi backoff ≥15s do chính lần discard tạo ra. Thay bằng `slot.reset()` ở cả 4 format. **KHÔNG dùng `beginReload()`** như ghi chú audit gợi ý: nó đẩy slot sang `loading` khi không có load nào chạy, và refill kế tiếp bị `if (isLoading) return false` từ chối ⇒ slot kẹt `loading` không watchdog — tệ hơn bug gốc. | `admob_adapter_test.dart` → `m15 — a stale discard does not poison the reload backoff` (cả 4 format) | `Expected: <0> / Actual: <1> / appOpen: an expiry is not a load failure` |
| m16 | `isAdFresh` không có chặn dưới ⇒ clock lùi cho `age` âm ⇒ "fresh" mãi. Thêm `if (age.isNegative) return false`. | `admob_adapter_test.dart` → `m16 — a loadedAt in the future (clock moved back) is NOT fresh` + group hành vi `m16 — clock moved backwards does not make a stale ad look fresh` (showAppOpen/showInterstitial). Không cần inject clock: đóng dấu `lastLoadedAt` ở tương lai **chính là** trạng thái clock lùi để lại. | `Expected: false / Actual: <true>` và `Expected: null / Actual: DateTime:<2026-08-23 01:33:49>` |
| m18 | `canShowInterstitial()`/`canShowRewardedAd()` dừng ở `isReady`. Thêm `AdMobAdapter.isFullscreenSlotFresh(slot)` (giữ `_fullscreenExpiryHours` private) và gọi qua `ad is AdMobAdapter` — **cùng shape với `reviveNativeInstance`** ở `:1683`, không đổi interface `AdProviderAdapter` đã export. AdMob-only vì MAX tự quản cache, không document expiry (m17). | `ad_manager_core_test.dart` → `m18 — a stale (>1h) ready AdMob slot is not reported as showable` (dùng `AdMobAdapter` thật qua `debugSetAdapter`, không dùng fake của group) | `Expected: false / Actual: <true>` |
| m22 | `Future.delayed` không handle ⇒ retry còn gọi bridge ~1.7s sau `dispose()`. Đổi sang `Timer` thật theo dõi trong `_destroyRetryTimers`, cancel ở đầu `dispose()`. | `applovin_adapter_test.dart` → `m22 — dispose() cancels the pending destroyWidgetAdView retry` (fakeAsync, bridge luôn reject như native thật khi AdView còn attach) | `Expected: [1] / Actual: [1, 1, 1, 1]` |
| m24 | Vòng lặp trong `dispose()` chỉ đi qua map **slot**; `banner/mrec/native(key)` và (AppLovin) `appLovinBannerAdViewId/appLovinMrecAdViewId(key)` tạo entry riêng độc lập với slot ⇒ key chỉ có notifier mà không có slot bị bỏ sót. Giờ iterate **hợp** của mọi map per-key, ở **cả 2 adapter**. | `admob_adapter_test.dart` → `m24 — listenables created without a slot are disposed too`; `applovin_adapter_test.dart` → `m24 — per-key notifiers created without a slot are disposed too`. **Lưu ý:** test `dispose()` có sẵn resolve notifier SAU dispose nên nhận singleton đã-dispose ⇒ xanh bất kể có bug hay không; test mới resolve TRƯỚC. | `Expected: throws <Instance of 'FlutterError'> / Actual: <Closure: () => void> / Which: returned <null>` |
| m36 | Cả 4 wrap null `fullScreenContentCallback` nhưng không null `onPaidEvent` ⇒ paid-event muộn vẫn `_emit` doanh thu cho ad đã chết. | `gma_bridge_test.dart` → group `m36 — dispose() unwires onPaidEvent` (4 test). Test **lái đúng đường dispatch platform→Dart thật** (`onAdEvent`/`onAdLoaded` qua `AdMessageCodec`) để lấy wrap production, rồi bắn đúng field mà `_invokePaidEvent` của plugin gọi — không dựng wrap giả. Đây là lần đầu file này chạm được `_XxxWrap` thật (trước ghi "out of proportion"). | cả 4: `Expected: null / Actual: <Closure: (Ad, double, PrecisionType, String) => void>` |

## Không phải bug / đã fix từ trước (3) — đã đọc code hiện tại, KHÔNG sửa

- **m23 — ĐÃ FIX RỒI.** `admob_adapter.dart` `disposeMrecInstance` hiện có `_mrecRoutePausedByKey.remove(key)` kèm comment "Minor (round 5)". Đóng mục.
- **m19 — KHÔNG reachable.** Consent-gate gọi `disposeBannerInstance(this)` rồi `_allowed.value = false`; cả hai đồng bộ trong cùng một turn, và không có build/paint nào xen giữa. Frame kế tiếp: `ValueListenableBuilder` đọc `_allowed` **đã** là `false` ⇒ trả `SizedBox.shrink()`, `AdWidget` không bao giờ được build lại với ad đã dispose. Kể cả nếu có rebuild sớm hơn, `buildAdmobBannerView(key)` đọc `_bannerAdsByKey[key]` — entry đã bị xoá ⇒ trả `null`. Đảo thứ tự 2 dòng cũng không thay đổi gì (vẫn cùng frame), còn hoãn dispose sang frame sau thì **xấu hơn về compliance** (ad sống thêm 1 frame sau khi rút consent). Không sửa.
- **m20 — KHÔNG reachable.** `disposeBannerInstance/Mrec/Native` gọi `_xAdsByKey.remove(key)?.dispose()`; `Ad.dispose()` → `instanceManager.disposeAd(ad)` → `_loadedAds.remove(adId)` (verified trong `google_mobile_ads-7.0.0/lib/src/ad_instance_manager.dart:683-692`). Sau đó handler `onAdEvent` tra `adFor(adId)` được `null` và chỉ `debugPrint` — plugin **không thể** gọi listener nữa. Guard thêm vào sẽ là code phòng thủ không có đường thật nào chạm tới, và test duy nhất viết được phải bắn listener thủ công qua `debugBannerListenerFor` — tức là test một tình huống production không tạo ra được. Không sửa (đúng loại với m4/M-4 phiên trước).

## Để mở có lý do (1)

- **m25 — `NativeAdWidget` không `with RouteAware`.** Đây là **quyết định thiết kế, không phải rò rỉ**, nên theo yêu cầu "không chắc thì dừng": banner/MREC pause được vì chúng **có** ticker auto-refresh để tắt (`autoRefreshEnabled` + `setBannerRoutePaused/setMrecRoutePaused`). Native ad **không có** ticker đó ở cả 2 provider — chính comment trong `admob_adapter.dart` nói `adSize/autoRefreshEnabled/visible` của native là "unused stubs", và không tồn tại `setNativeRoutePaused` ở bất kỳ đâu trong `lib/`. Thêm `RouteAware` vào đây sẽ phải **phát minh** một semantic pause cho native (destroy+reload khi bị route khác che? chỉ ẩn?), mỗi lựa chọn có đánh đổi thật về fill rate và impression. Cần chủ sản phẩm quyết, không phải agent đoán.

## Ghi chú cho phiên sau

1. `packages/ad_sdk/example/pubspec.lock` bị `flutter pub get` ghi lại (`ad_sdk 2.3.1` → `2.3.2`) mỗi lần chạy `flutter analyze`/`flutter test`. File đang commit ở `2.3.1`. Phiên này `git checkout` nó trước mỗi commit để giữ tree sạch — hoặc commit lại một lần cho xong.
2. Còn tồn (không thuộc VIỆC 3): **M1 cho mrec/native**, **m4** (unreachable, đã ghi lý do), **VIỆC 4 / MJ9** (VIP clock-forward — vẫn chưa bắt đầu, vẫn là mục rủi ro cao nhất), và các mục MINOR chưa xử: m1–m14, m17, m21 (đã fix ở `e300c76`), m26–m35, m37, m38.

---

# QC vòng 3 (26 commit) + smoke bản published 2.3.2 — 2026-08-23

## Điểm từ hai reviewer độc lập, chạy tuần tự trên cùng `git diff e7fed4f..HEAD`

| Reviewer | Điểm | Finding |
|---|---|---|
| agy | **8.5/10** | 1 Major thật (xem dưới) |
| codex | **8.0/10** | Không Blocker/Major mới; trừ điểm ở câu chữ claim M-4 và ở việc một phần "đỏ" của thí nghiệm tổng hợp đến từ compile-error do mất test seam, không phải hành vi |

Lần đầu cả hai reviewer cùng ở mức 8+. Bốn vòng trước: 6, 5, 5, và 8.5/5.

## Con số quyết định — đã đảo hẳn

| | Vòng 1 | Vòng 3 |
|---|---|---|
| Fix revert được **mà suite vẫn xanh** | **20/24** | **0/22** |
| Revert đồng thời toàn bộ `lib/` | — | agy: **90/951 test đỏ** · codex: **19 suite đỏ** (14 assertion + 5 compile) |

Hai con số aggregate lệch nhau vì hai reviewer đếm khác đơn vị (test lẻ vs suite). Điểm chung quan trọng: **không còn fix nào lọt lưới khi revert đơn lẻ**.

Lưu ý công bằng của codex đáng ghi lại: một phần "đỏ" của thí nghiệm tổng hợp là **compile error do xoá `@visibleForTesting` seam**, không phải test bắt được hành vi sai. Thí nghiệm aggregate vì vậy là chỉ báo thô; con số đáng tin là 0/22 khi revert từng fix.

## Major agy tìm ra — đã sửa (`391ea52`)

`canShowRewardedInterstitialAd` **thiếu** kiểm freshness, trong khi `canShowInterstitial` và `canShowRewardedAd` đã có. m18 wire vào 2/3 format fullscreen rồi tuyên bố xong ⇒ format thứ ba vẫn trả `true` cho ad mà đường show sẽ loại ngay — đúng triệu chứng host-visible mà m18 được viết ra để xoá. Test viết trước, quan sát đỏ (`Expected: false / Actual: <true>`) trước khi thêm guard.

**Bài học lặp lại lần thứ năm:** dạng lỗi hay lọt nhất không phải "quên sửa" mà là **"sửa phần lớn rồi tưởng là hết"**. Nên với mỗi fix áp cho một họ (3 format fullscreen, 4 call site, 2 provider), phải đếm rõ họ đó có mấy phần tử và đã áp đủ chưa.

## Smoke bản published 2.3.2 trên app consumer thật

Dựng app Flutter mới, kéo `applovin_admob_sdk: ^2.3.2` **từ pub.dev** (không phải path local), kèm combo known-good `gma_mediation_applovin 2.5.2` + `dependency_overrides: applovin_max 4.6.0`.

| Cửa | Kết quả |
|---|---|
| `flutter pub get` | ✅ resolve 2.3.2, `applovin_max 4.6.0`, `gma 2.5.2`, `google_mobile_ads 7.0.0`, `meta 1.16.0` |
| `pod install` | ✅ 16 pod — `AppLovinSDK 13.5.0` thoả **cả hai** pin tuyệt đối (`applovin_max` và `GoogleMobileAdsMediationAppLovin 13.5.0.0`) |
| `flutter build apk --debug` | ✅ |
| `flutter build ios --simulator --debug` | ✅ |

Đây là kiểm chứng mà 952 unit test và `--dry-run` **không** thay được: `--dry-run` từng báo "0 warnings" ngay trước hai lần upload thất bại thật, và `pub get` xanh không nói gì về pod graph.

Kết quả kèm theo: `tool/check_pinning_wall.sh` được siết (`a93f40a`) — trước đó chỉ chạy `pub get` + `pod install` và **tin vào exit code**. CocoaPods exit 0 ngay khi tìm được *một* giải pháp, kể cả giải pháp âm thầm dịch pod ta muốn giữ. Script giờ assert version `AppLovinSDK` thực sự giải ra, và **đã kiểm cả hai chiều**: đặt kỳ vọng sai ⇒ exit 1 kèm tên pin lệch; đặt đúng ⇒ exit 0. Thêm build thật sau cờ `--with-builds` (tắt mặc định, ~8 phút).

---

## m25 — native `RouteAware`: QUYẾT ĐỊNH KHÔNG LÀM (2026-08-23)

Reviewer trước để mở mục này với lý do "cần chủ sản phẩm quyết vì đánh đổi fill-rate/impression". Sau khi đọc code thì đánh đổi đó **không cân** như tưởng, nên ghi lại kết luận kèm dữ kiện để không phải điều tra lại.

**Vì sao banner/MREC có `RouteAware` mà native không cần:** banner và MREC **sở hữu bộ đếm tự làm mới**, nên khi bị route khác che, chúng sẽ tiếp tục nạp ad mới trong lúc không ai nhìn — pause là để chặn việc đó. Native **không có ticker** (`native_ad_widget.dart` dartdoc, và không tồn tại `setNativeRoutePaused` ở bất kỳ đâu trong `lib/`). Không có gì để "tạm dừng".

**Thứ duy nhất `RouteAware` có thể thêm cho native là huỷ ad view khi bị che — và nó đánh đổi chính cái cache đang có:**

| Provider | Hiện trạng | Nếu huỷ khi bị che |
|---|---|---|
| AdMob | ad đã nạp nằm trong `_nativeAdsByKey` của adapter ⇒ quay lại là hiện ngay | xoá cache ⇒ mỗi lần quay lại tốn 1 request + khoảng trống chờ |
| AppLovin | `MaxNativeAdView` tự chứa, **không có preload bridge** nên vốn không cache được | nạp lại vô điều kiện, mỗi lần quay lại |

Không chiều nào mua thêm được impression. Người dùng đi qua lại nhiều lần thì thành đốt request mà không tăng doanh thu.

**Ca thật sự cần teardown đã được xử lý:** một feed dài toàn native — `ListView` đã tự dispose item rời khỏi vùng nhìn, và đường đó đi qua `disposeNativeInstance`. Phần còn giữ chỉ là **một ad view cho mỗi màn hình đang mount**.

**Đã cân nhắc và loại:** huỷ sau một khoảng chờ (~30s bị che). Được cả hai chiều về lý thuyết, nhưng cần thêm một timer phải track/cancel — đúng loại lỗi vừa phải sửa ở **m22** (`Future.delayed` không cancel, gọi vào bridge đã teardown). Không đáng đổi một lỗi đã biết lấy một khoản tiết kiệm bộ nhớ nhỏ.

Chú thích do-not-fix đã đặt trong dartdoc của `NativeAdWidget`.
