# Audit tổng hợp `applovin_admob_sdk` — Claude (bản hợp nhất)

**Đây là bản hợp nhất** của toàn bộ các round audit do Claude thực hiện từ 2026-08-02 đến 2026-08-19 (5 file gốc: `audit_claude.md` 08-09, `audit_claude_20260802.md`, `audit_claude_native_20260815.md`, `audit_claude_20260819.md`, `audit_claude_external_20260819_round2.md` — chạy độc lập qua `claude --dangerously-skip-permissions`), cộng thêm một vòng audit mới (2026-08-19/20, 7 lane nội bộ chạy song song + đối chiếu chéo với vòng external). File cũ đã bị xoá, nội dung được giữ lại và đánh dấu **stale/fixed** nếu đã lỗi thời.

**Version audited:** local `pubspec.yaml` = **2.1.0** (đã release theo git log: `51e79e6`, `95c12e8`, ngày 2026-08-19). pub.dev có thể còn đang serve `2.0.4` do CDN cache lag (xem CLAUDE.md mục publish traps) — **verify trực tiếp trên pub.dev trước khi ai đó pull package cho production**, đừng tin theo ngày commit.
**Test status:** `flutter test` → **860/860 pass**. `flutter analyze` → **0 issues**.
**Phương pháp:** 7 lane nội bộ độc lập (A: platform/provider parity; B: offline/online; C: ad-type lifecycle/leak; D: trial+VIP; E: consent+policy; F: example+docs; cộng 3 finding tự phát hiện ngoài lane) — mỗi lane đọc source trực tiếp, cite `file:line`, không thấy kết quả của lane khác trước khi report. Đối chiếu chéo với 1 vòng `claude --dangerously-skip-permissions` độc lập (file gốc `audit_claude_external_20260819_round2.md`) và với `agy` CLI. Finding được cả 2+ nguồn độc lập tìm ra được đánh dấu **[cross-confirmed]** — độ tin cậy cao nhất.

---

## Blocker (fix trước khi ship)

### B1 — AppLovin banner/MREC native view leak khi widget đang hiển thị (attached) lúc dispose **[cross-confirmed: lane C + external-claude M2 + agy round2 xác nhận call tồn tại nhưng không xác minh sâu]**
`applovin_adapter.dart:140-239` (`disposeBannerInstance`/`disposeMrecInstance`) gọi `destroyWidgetAdView(id)` không điều kiện (fix ngày 08-19, commit `5fb7a58`, đã đóng finding cũ "không gọi destroy"). Nhưng verify trực tiếp native source (`applovin_max-4.6.4/android/.../AppLovinMAXAdView.java:70-103`, và bản iOS `.m` tương ứng) xác nhận: nếu `preloadedWidget.hasContainerView()` còn `true` (view vẫn đang attach vào cây widget) thì native **từ chối destroy**, trả lỗi `"Cannot destroy - the preloaded AdView is currently in use"` — Dart side chỉ log warning (`unawaited(...).catchError(...)`) và bỏ qua. `banner_ad_widget.dart:180-199` gọi `disposeBannerInstance` đồng bộ ngay trong `State.dispose()`, **trước khi** native platform view thực sự detach — đúng lúc `hasContainerView()` còn true. Kết quả: native `MaxAdView`/ad instance rò rỉ mỗi lần widget bị dispose trong lúc còn hiển thị (route pop khi banner đang trên màn hình — trường hợp phổ biến, không phải edge case).
**Vì sao nghiêm trọng:** rò rỉ tích lũy theo số lần điều hướng, không phải sự cố hiếm; xảy ra trên path chính (banner ở mọi màn hình có back navigation).
**Sửa:** đợi native platform view báo detach xong (callback hoặc `postFrameCallback` sau khi view bị remove khỏi tree) rồi mới gọi destroy, hoặc retry destroy sau delay ngắn nếu lần đầu bị native từ chối.

### B2 — COPPA bypass qua timing của pending-consent replay
`ad_manager.dart:1855-1884` replay `_pendingConsentSettings` (buffer khi `setConsent()` được gọi trước lúc `_consentManager` bootstrap xong) **sau** `adapter.initialize()` (gọi ở `:1799`, còn replay ở `:1867-1873`). Nếu host gọi `setConsent(isAgeRestrictedUser: true)` trên máy mới cài **trước** `initialize()` — đúng pattern khuyến nghị cho COPPA — giá trị bị buffer nhưng tới quá muộn để gate AppLovin's init: `applovin_adapter.dart:365-394` chỉ chặn init khi `isAgeRestrictedUser` **tại thời điểm gọi initialize** là `true`; do buffer replay muộn, adapter nhận `false` và AppLovin SDK khởi tạo bình thường cho user đã được host đánh dấu là trẻ em.
**Vì sao nghiêm trọng:** vi phạm trực tiếp COPPA/AppLovin child-directed policy — SDK track/serve ad cá nhân hoá cho user host đã minh bạch flag là bị hạn chế tuổi.
**Sửa:** `initialize()` phải chờ/đọc `_pendingConsentSettings` (nếu có) **trước** khi construct/init adapter, không phải sau.

### B3 — VIP clock forward-rồi-lùi làm đông cứng vĩnh viễn entitlement **[cross-confirmed: lane D B1 + external-claude M4]**
`vip_manager.dart:178-198` (`_effectiveNow()`) chỉ clamp theo chiều **chống lùi** (nếu đồng hồ hiện tại < high-water mark đã lưu thì dùng mark), nhưng **không bao giờ nâng mark lên** khi đồng hồ quan sát được đã vượt mark. Kịch bản: user chỉnh đồng hồ tiến (VD +30 ngày) rồi chỉnh lại đúng — mark đã bị đẩy lên tương lai vĩnh viễn, `_effectiveNow()` từ đó luôn trả về ít nhất giá trị mark đó dù đồng hồ thật đã lùi về đúng. Hệ quả ngược của mục đích chống rollback: VIP có thể bị coi là **hết hạn ngay lập tức** (nếu forward vượt quá `expiresAt`) dù thời gian thật chưa tới, hoặc bị đông cứng tại một mốc tương lai sai.
**Vì sao nghiêm trọng:** user trả tiền/redeem VIP hợp lệ bị mất quyền lợi do một lần chỉnh giờ vô tình (đổi timezone, đồng bộ NTP lỗi) — không phải hành vi gian lận.
**Sửa:** high-water mark cần được note là "mark tối đa từng quan sát", nhưng phải cho phép đồng hồ thật tăng trở lại vượt mark trong tương lai (mark chỉ chống *lùi dưới giá trị đã thấy*, không nên tạo sàn cao hơn hiện tại một khi đồng hồ thật đã vượt qua rồi lùi lại đúng — cần thiết kế lại tiêu chí "đã thấy" để không tự khoá vào giá trị outlier).

---

## Major

### M1 — `rewardedInterstitialSlot` thiếu trong fullscreen busy-reason mutex **[cross-confirmed: lane C B2 + external-claude M3]**
`ad_manager.dart:960-992` (`_fullscreenBusyReason` getter) chỉ check `appOpenSlot.isShowing`, `interstitialSlot.isShowing`, `rewardedSlot.isShowing`, `AdLoadingDialog.isShowing`, `AdScreenRouteLogger.isDialogOnTop` — thiếu `rewardedInterstitialSlot.isShowing`. Rewarded Interstitial có thể show đồng thời với 1 fullscreen ad khác → ad stacking, vi phạm chính sách AdMob/AppLovin cả hai.
**Sửa:** thêm `rewardedInterstitialSlot.isShowing` vào điều kiện.

### M2 — AVP2 expiry check bỏ qua anti-rollback clamp **[cross-confirmed: lane D M1 + external-claude m2]**
`vip_manager.dart:636-660` (`redeemSignedKey`) không truyền `now:` vào `verifySignedVipKey`, nên `signed_vip_key.dart:195-206` fallback `DateTime.now()` chưa qua clamp của `_effectiveNow()`. Redeem-time expiry check dùng đồng hồ thiết bị thô — user chỉnh lùi đồng hồ có thể redeem key đã hết hạn hoặc kéo dài hạn dùng giả.
**Sửa:** truyền `_effectiveNow()` vào lời gọi verify tại `redeemSignedKey`.

### M3 — AppLovin không có khái niệm ad-freshness; App Open show từ slot `ready` không re-check tuổi tại thời điểm show
Đã fix cho AdMob (commit `05326ed`, 08-19: freshness check giờ chạy ở show-time cho cả 4 loại fullscreen AdMob, không chỉ ở load/reuse). AppLovin (MAX) hoàn toàn không có concept freshness — không phải bug của SDK (native AppLovin SDK không expose timestamp) nhưng **là gap chính sách thực tế**: nếu provider = AppLovin, App Open có thể hiển thị ad đã cache rất lâu. Ghi nhận là giới hạn cố hữu của nền tảng AppLovin, không phải lỗi code có thể tự sửa trong SDK này.

### M4 — Rewarded Interstitial trên AppLovin báo `shown: true` giả **[cross-confirmed: lane C M9 + external-claude m3]**
`applovin_adapter.dart:1226-1230` (`showRewardedInterstitial`) là no-op ngay lập tức gọi `onDone(RewardResult.skipped)` (AppLovin MAX không có format này) nhưng orchestrator ở `ad_manager.dart` hard-code `shown: true` bất kể kết quả thật. Host code không phân biệt được "đã hiển thị nhưng không có reward" với "provider không hỗ trợ format này".
**Sửa:** orchestrator dùng đúng field `shown` từ kết quả adapter trả về, không hard-code.

### M5 — AppLovin `preloadBanner`/`preloadMrec` không gọi `beginLoad()`, overwrite `adViewId` không destroy cái cũ
`applovin_adapter.dart:1378-1415`, `:1442-1487` (theo báo cáo lane C, chưa tự đọc lại dòng chính xác trong vòng này — giữ nguyên với ghi chú "chưa re-verify 08-19/20", ai audit sau nên đọc lại trước khi đóng finding). Nếu đúng như báo cáo: mỗi lần preload lại một slot đã có `adViewId` cũ sẽ leak view cũ tương tự B1, độc lập với B1's timing issue.

### M6 — `showAppOpenAdOnResume` từng bypass toàn bộ safety cap ngoài phạm vi splash — **đã fix**
`ad_manager.dart:2719-2722` (bản cũ trước 08-19) luôn gọi `showAppOpenAd(bypassSafety: true, ...)` bất kể là splash hay resume thường. Đã fix commit `6ca3d78` (08-19): resume path giờ dùng `bypassSafety: false`, chỉ splash flow còn bypass. **Giữ mục này để ai đọc CHANGELOG không tưởng đây còn mở.**

### M7 — CHANGELOG `[Unreleased]` (13 feature + batch fix security 08-16/17) chưa publish lên pub.dev tại thời điểm audit 08-19 — **cập nhật: đã release 2.1.0**
Tại thời điểm audit 08-19, pub.dev còn serve 2.0.4, thiếu fix domain-separation CRL/VIP-key, stale-watchdog fix, connectivity-race fix. Git log hiện tại cho thấy `2.1.0` đã được release (`51e79e6`, `95c12e8`, 2026-08-19). **Vẫn cần xác nhận thủ công trên trang pub.dev** rằng phiên bản đã lên thật (không chỉ commit local) trước khi coi finding này đã đóng — CDN pub.dev có thể lag vài phút theo ghi chú trong CLAUDE.md.

### M8 — Undocumented breaking API change (tự phát hiện)
`MIGRATION.md` không đề cập 3 breaking change tự nêu trong CHANGELOG 2.0.0 (`autoRequestUmpConsent` default `false→true`, VIP key format `AVP1→AVP2`, `maxVipStackDuration` default `null→90 days`). Host upgrade từ 1.x không có hướng dẫn cho bất kỳ thay đổi nào trong 3 cái này; file FAQ vẫn ghi "2.0 hiện chưa release" dù 2.0.4/2.1.0 đã release từ lâu.

### M9 — ATT trigger ngầm qua `advertising_id` package, độc lập với `requestAtt()` (tự phát hiện)
`ad_manager.dart:1570-1584` gọi `AdvertisingId.id(true)`; xác nhận qua source `advertising_id-2.7.1/ios/.../SwiftAdvertisingIdPlugin.swift:8-22` — hàm này tự gọi `ATTrackingManager.requestTrackingAuthorization` **native** bất cứ khi nào status chưa `.authorized`, không phụ thuộc vào việc host có gọi SDK's `requestAtt()` Dart method hay chưa.
**Vì sao đáng chú ý:** SDK có thể trigger prompt ATT hệ thống iOS **sớm hơn** ý định của host (nếu host gọi initialize trước khi họ tự quyết định thời điểm show ATT prompt theo Apple guideline "show trong context phù hợp"), gây risk UX/App Review nếu prompt xuất hiện đột ngột không có giải thích trước.
**Sửa:** tối thiểu là document rõ hành vi này trong README; lý tưởng là cho phép host defer việc gọi `AdvertisingId.id(true)` tới sau khi `requestAtt()` chạy.

### M10 — CRL không thể thu hồi ngược grant đã cấp (đã biết, ghi lại rõ)
Xem mục "Known limitations" — không phải bug, nhưng cần liệt kê ở đây vì ảnh hưởng mức Major tới bảo mật VIP nếu 1 key private bị lộ và cần blocklist khẩn.

---

## Minor

- **m1** — `umpTagForUnderAgeOfConsent` không lan tới thực tế ad request path (cần verify lại dòng chính xác — ghi từ external-claude, chưa tự đọc lại).
- **m2** — Empty ad-unit-ID crash guard chỉ có cho MREC, không có cho banner/native.
- **m3** — Test-ad-unit-ID footgun detection chỉ cover 4/7 loại ad **[cross-confirmed: lane A F7 + external-claude m5]**.
- **m4** — `rewardedInterstitialSlot`'s notifier không được dispose.
- **m5** — Native awaits trong `initialize()` không bounded đầy đủ (một số nhánh) **[cross-confirmed: lane B B2 + external-claude m7]**.
- **m6** — Comment stale trong example app nói UMP "không có timeout" — sai, có timeout 20s (`ump_consent.dart:105-108`).
- **m7** — `_lastBackgroundTime` (agy 1.6) có thể giữ mốc cũ nếu Android bắn `paused`/`resumed` dồn nhanh (permission dialog, notification shade) — khiến `minTimeAppOpenResume` bị bỏ qua ngoài ý muốn. Chưa tự verify lại trong vòng này.
- **m8** — `AdEventLog` ghi `SharedPreferences` mỗi sự kiện đơn lẻ (không debounce/batch) — có thể gây jank nếu tần suất event cao (agy 2.1). Enhancement hơn là bug.
- **m9** — `AdSafetyConfig._lastBackgroundTime`, `MonetizationArbitrator` eCPM ×1000 scale bug do agy 08-15 nêu (1.2) — **cần verify lại**: nếu đúng, đây phải là Major/Blocker vì gây veto gần 100% ad. Không tự đọc lại `monetization_arbitrator.dart:35,47-48,106-110,134-148` trong vòng audit này — flag ưu tiên cao cho vòng sau xác minh trực tiếp, chưa đủ cơ sở để xếp hạng chính thức ở đây.

---

## Confirmed-correct

- Toàn bộ 49 method của `AdProviderAdapter` được cả `AdMobAdapter` và `AppLovinAdapter` implement thật, không stub; 2 phân kỳ có chủ đích (rewarded-interstitial không hỗ trợ AppLovin; AppLovin init fail-closed khi COPPA) đều log rõ, không âm thầm.
- Mọi `await` chạm network trong `initialize()`/connectivity path đều có `.timeout()`; ad load fail-fast khi offline; generation-token guard trên `_startConnectivityWatch` chống race từ nhiều lần gọi chồng.
- Ed25519 verify hoàn toàn offline, private key không ship, không có fallback verify không an toàn — binary decompile không thể tự tạo key hợp lệ. CRL domain-separation (`AVP1|`, `AVP2|`, `CRL1|`) chống replay chéo format.
- Safety layer: daily/hourly/session cap, 30 phút throttle, CTR fraud detection, progressive cooldown 30min→24h, `dryRun` bị force off ở release build.
- GDPR/CCPA: UMP + AppLovin CMP + `RequestConfiguration`/`AppLovinPrivacySettings` wired đúng cả 2 provider; UMP lỗi channel fail-safe theo hướng gate đóng ở phần lớn code path (ngoại trừ M3/finding cũ về fail-open đã note ở audit_codex.md).
- README/CHANGELOG/MIGRATION đối chiếu code từng mục (safety-cap default, `FirstInstallVipGrace.auto`, `maxVipStackDuration`, `autoRequestUmpConsent` default) đều khớp — trừ các gap M7/M8 đã nêu.
- Example app: có đủ demo cho toàn bộ 4 loại ad + VIP redeem + consent flow, dùng path dependency (test đúng source hiện tại), có comment tự nhận diện các simplification.

---

## Known-and-disclosed limitations (không phải bug, nhưng phải hiểu trước khi ship)

- CRL không thể thu hồi ngược VIP grant đã cấp trước đó — chỉ chặn redeem key mới.
- Android reinstall re-grant trial + re-redeem VIP key nếu host không tự wire Android Auto Backup (`allowBackup`, `dataExtractionRules`, `fullBackupContent`) — SDK không tự warn runtime nếu host quên (chỉ document trong README).
- AVP2 bundle-id binding fail-open nếu không đọc được bundle ID thật (theo thiết kế, tránh false-negative chặn user hợp lệ).
- AppLovin không nhận runtime signal COPPA — thiết kế cố ý fail-closed lúc init vì AppLovin MAX 4.x không có API tương đương `tagForChildDirectedTreatment`.
- Consent revocation giữa phiên không tự discard cached creative đã load trước đó (chỉ chặn request mới).

---

## Khuyến nghị cuối: có nên dùng SDK này cho production app không?

**YES — WITH CONDITIONS.** Kiến trúc tổng thể (adapter 2 provider, state machine slot, safety layer 12 tầng, VIP Ed25519 offline, watchdog) là hàng chất lượng production thật, không phải wrapper viết vội — 860 test pass, `flutter analyze` sạch, đã qua 12+ vòng audit độc lập với xu hướng số lượng Blocker/Major giảm dần qua mỗi vòng.

**Điều kiện bắt buộc trước khi ship:**
1. Fix **B1** (AppLovin banner/MREC native view leak) trước khi bật provider AppLovin cho bất kỳ app nào có traffic thật, đặc biệt app có nhiều banner + navigation.
2. Fix **B2** (COPPA bypass timing) trước khi ship cho bất kỳ audience có khả năng chứa trẻ em/age-restricted user.
3. Fix **B3** (VIP clock forward-rồi-lùi đông cứng) trước khi có VIP user trả tiền thật — đây là bug ảnh hưởng trực tiếp doanh thu/trải nghiệm người dùng trả tiền.
4. Fix hoặc tối thiểu tắt tính năng Rewarded Interstitial (**M1**, **M4**) cho tới khi mutex và report kết quả đúng.
5. Xác nhận trực tiếp trên pub.dev rằng version đang serve là 2.1.0 (không phải 2.0.4) trước khi bất kỳ app pull package qua pub.dev thay vì git ref/path — nếu chưa, pin git ref `main` hoặc publish thủ công trước.
6. Verify lại **m9** (nghi vấn eCPM scale ×1000 trong `MonetizationArbitrator` do agy nêu) — nếu đúng, nâng lên Blocker vì có thể veto gần 100% ad revenue.

Nếu 3 Blocker trên và điều kiện 5 được xử lý, khuyến nghị chạy production không cần dè dặt thêm.
