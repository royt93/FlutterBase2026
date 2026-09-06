# Audit round 40 — Gemini (`agy --dangerously-skip-permissions`)

**Run against:** the same isolated `rsync` copy of the repo at
`/tmp/audit_r40_copy` used for the codex pass.
**Note on isolation:** per prior-round experience (`agy` has previously
written its report to its own internal scratch path — e.g.
`~/.gemini/antigravity-cli/scratch/REVIEW_REPORT.md` — instead of the path
requested in-prompt, with file links resolving to the real working tree),
this run's output file was located and copied out immediately after the
process exited, and the real repo's `git status`/`git log` were checked
right after — no source file was touched, no commit/push happened, only the
requested `AUDIT_OUTPUT.md` (verified this run wrote to the correct
requested path this time) and its own log file were created in the isolated
copy.

`agy` was given the same 7-criteria brief as the in-session Claude audit and
`codex exec`, without seeing this session's context or the other two
reviewers' output.

---

## I. Tổng quan và điểm đánh giá (executive summary)

Sau 39 vòng audit và tái cấu trúc liên tục, codebase `applovin_admob_sdk` đã
đạt mức độ hoàn thiện, chặt chẽ và an toàn rất cao. Trong Round 40, hệ thống
đã được rà soát adversarial độc lập toàn diện:

- **BLOCKER:** **0** (Không có lỗi dừng hệ thống hoặc vi phạm chính sách cấp
  độ đình chỉ tài khoản).
- **MAJOR (Code Bug mới):** **0** (Các vấn đề race condition, state desync,
  lifecycle leaks từ các vòng trước đều đã được xử lý triệt để với
  regression tests đi kèm).
- **MINOR / NITPICK (Cải tiến/Khuyến nghị):** **0** (Toàn bộ các vi chỉnh về
  guard, delay, timeout và barrier đã được làm sạch trong R39v2).
- **ACCEPTED ARCHITECTURAL LIMITATIONS (Giới hạn kiến trúc đã chấp thuận):**
  **2** (Trial bypass trên Android khi tắt Auto Backup; Replay mã VIP hợp lệ
  qua nhiều thiết bị do kiến trúc offline backend-free).
- **FALSE-POSITIVES ĐÃ XÁC MINH CƠ CHẾ:** **6** (Xem chi tiết từng mục bên
  dưới).

### **ĐIỂM ĐÁNH GIÁ TỔNG THỂ: 9.8 / 10**
**Khuyến nghị đưa vào Production:** **SẴN SÀNG (PRODUCTION READY)**.

> **Ghi chú xác minh chéo của phiên Claude điều phối:** `codex exec`'s độc
> lập chạy song song trên cùng bản copy đã tìm ra 1 MAJOR mà `agy` bỏ lỡ ở
> đây — GPP multi-section priority-order có thể bỏ sót tín hiệu opt-out thật
> (xem `audit_codex.md` mục R40-02, và `audit_round40_consolidated.md`).
> `agy`'s "0 MAJOR mới" claim ở tiêu chí 6 dưới đây, vì vậy, **không được
> chấp nhận nguyên văn** — giữ lại báo cáo gốc của `agy` không sửa, nhưng
> điểm tổng kết ở file consolidated phản ánh finding thật đó. Đây đúng bài
> học "self/single-review điểm cao vẫn có thể miss cái reviewer khác bắt
> được" đã ghi trong project memory.

---

## II. Đánh giá chi tiết theo 7 tiêu chí bắt buộc

### Tiêu chí 1: Provider adapter (AdMob / AppLovin) trên Android và iOS

**Phạm vi mã nguồn:** `lib/src/adapters/admob_adapter.dart`,
`lib/src/adapters/applovin_adapter.dart`, `lib/src/adapters/gma_bridge.dart`,
`lib/src/adapters/applovin_bridge.dart`, `lib/src/adapters/_inline_visibility.dart`.

**Cơ chế hoạt động và xác minh thực tế:**
- **AdMob Adapter:** Sử dụng GMA Bridge pattern giúp phân tách hoàn toàn
  giữa logic quản lý vị trí quảng cáo và plugin `google_mobile_ads`
  (`gma_bridge.dart:18-80`). Toàn bộ tham số cấu hình request (NPA, RDP,
  Content Rating Max, COPPA/TFUA) được truyền qua per-request extras và
  RequestConfiguration (`admob_adapter.dart:80-95, 780-840`). Quản lý vòng
  đời hiển thị Fullscreen độc quyền qua `_inheritFullscreenHold` và
  `InlineVisibilityOwners` (`admob_adapter.dart:28-56`).
- **AppLovin MAX Adapter:** Kiểm tra danh tính đối tượng quảng cáo
  `identical(ad, _appOpenAd/_interstitialAd/_rewardedAd)` tại callbacks
  (`applovin_adapter.dart:450-520, 890-950, 1420-1490`), triệt tiêu race
  condition khi nhiều chu kỳ load/show diễn ra gần nhau. Ẩn quảng cáo nội
  dòng qua native API `autoRefreshEnabled` (`applovin_adapter.dart:31-90`).
  `_destroyWidgetAdViewWhenDetached` retry có trễ tránh crash platform
  channel (`applovin_adapter.dart:1120-1180`).

**Findings:**
- Finding 1.1 (nghi vấn static listener nhầm lẫn sự kiện): **FALSE-POSITIVE**
  — verify tại `applovin_adapter.dart:495, 912, 1445`, mọi callback đối
  chiếu qua `identical` + generation/slot state.
- Finding 1.2 (nghi vấn platform channel type mismatch cho
  `adaptiveBannerWidth`/`templateType`): **FALSE-POSITIVE** — AdMob chuẩn
  hoá qua `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width.truncate())`
  (`admob_adapter.dart:620-650`).

### Tiêu chí 2: Khả năng chịu lỗi offline & kết nối mạng

**Phạm vi mã nguồn:** `ad_manager.dart`, `state/ad_retry_policy.dart`,
`state/backoff.dart`, `vip/vip_manager.dart`.

- Connectivity awareness qua `ConnectionNotifierTools`
  (`ad_manager.dart:5891-5915`); `VipManager._waitForConnectivity`
  (`vip_manager.dart:1277-1295`) poll 2 giây (chu kỳ 100ms) trước khi kết
  luận offline, tránh false-negative lúc khởi động.
- Reconnect kích hoạt debounce 500ms rồi refill (`_onConnectivityChanged`,
  `ad_manager.dart:7668-7710`).
- `AdRetryPolicy` backoff luỹ thừa + jitter, floor tối thiểu 10% base
  (`ad_retry_policy.dart:45-75`).
- Watchdog chống treo slot Fullscreen (App Open 90s, Interstitial/Rewarded
  30-45s); `VipManager.load()` multi-tier retry (2s/10s/45s) khi Keystore
  tạm khoá (`vip_manager.dart:210-270`).

- Finding 2.1 (nghi vấn request khi offline gây crash/spam log):
  **FALSE-POSITIVE** — mọi entry point có guard `if (!isConnected) return;`
  (`ad_manager.dart:5973, 6394, 6610, 7008`), chặn ngay tại Dart layer.

### Tiêu chí 3: Vòng đời và bảo mật bộ nhớ từng ad type

| Loại Ad | Lifecycle | Chống rò rỉ / Policy guard |
| :--- | :--- | :--- |
| Banner | RouteAware, TickerMode, VisibilityDetector (`banner_ad_widget.dart:78-146`); tham số `active` cho `IndexedStack`. | Hủy sạch listener + unsubscribe trong `dispose()` (`:443-455`); `_bannerInitCalled` phân biệt "chưa init" vs "đã pause". |
| MREC | RouteAware + VisibilityDetector (`mrec_ad_widget.dart:49-98`). | Hủy toàn bộ listener/instance trong `dispose()` (`:340-360`). |
| Native | Mount-driven; AdMob Template / AppLovin `MaxNativeAdView` (`native_ad_widget.dart:18-49`). | `_retryTimer?.cancel()` trong `dispose()` (`:240-254`). |
| App Open | Auto trigger on resume, debounce+throttle (`ad_manager.dart:2100-2250`). | `umpFormOnScreen` mutex + `AdScreenRouteLogger.isDialogOnTop` (`:2180-2210`). |
| Interstitial/Rewarded | Quản lý tập trung, cooldown + cap (`ad_manager.dart:6000-6500`). | Callback giải phóng đúng state machine. |

- Finding 3.1 (nghi vấn `IndexedStack` để lộ banner ngầm): **FALSE-POSITIVE**
  (đã xử lý R39/R39v2) — `active == false` chặn `_initBanner`/`_initMrec`
  tuyệt đối (`banner_ad_widget.dart:301-310`, `mrec_ad_widget.dart:100-120`).

### Tiêu chí 4: Trial mode 1 ngày

- iOS: cờ Keychain `ad_sdk_first_install_granted_v1` với
  `KeychainAccessibility.first_unlock` (`_first_install_guard.dart:98-106,
  198-204`) — sống sót qua reinstall, chặn farm.
- Android: dựa Android Auto Backup phục hồi `isFirstInstallGraceApplied`.
- Write-order: Keychain ghi trước SharedPreferences
  (`_first_install_guard.dart:177-186`) để an toàn khi force-kill giữa
  chừng.
- **Finding 4.1 (Accepted Architectural Limitation):** tắt Auto Backup +
  gỡ cài Android → nhận lại trial. Đã xác nhận R31/R39, chấp nhận vì SDK
  không backend.

### Tiêu chí 5: Kích hoạt VIP bằng mã (Ed25519 offline)

- `AVP1`/`AVP2` wire format, Ed25519, domain separation CRL1 cho revocation
  (`signed_vip_key.dart:86-125`).
- `RedeemedKeyLedger._writeChain` static, tuần tự hoá qua mọi instance
  `VipManager` (`_redeemed_key_ledger.dart:69-116`).
- `VipEntriesStore` mã hoá Keystore/Keychain; fallback plaintext bị đánh dấu
  `lastReadWasUntrustedFallback` và kẹp trần 24h
  (`_vip_entries_store.dart:80-100`, `vip_manager.dart:820-850`).
- Anti-rollback: `_effectiveNow()` kết hợp `DateTime.now()` +
  monotonic `Stopwatch` + high-water mark (`vip_manager.dart:365-381`).
- **Finding 5.1 (Accepted Architectural Limitation):** một mã hợp lệ có thể
  dùng trên nhiều thiết bị (không server trung tâm). Đã document, chấp
  nhận.

### Tiêu chí 6: Consent toàn cầu (GDPR/UMP, GPP, US Privacy, TCF)

- iOS/Android đọc đúng store UMP ghi (`iab_storage.dart:19-30`, tránh lỗi
  prefix `flutter.` và file sai).
- TCF Purpose 1/3/4 quyết định personalization; GPP US National + California
  + 19 bang được decode bit-packed (`iab_storage.dart:48-83, 200-380`).
- `ConsentManager._persist()` serialize qua `Completer`-based lock (R39 fix,
  `consent_manager.dart:95-120`).
- `umpFormOnScreen` reference-counted mutex + backstop 15 phút
  (`ump_consent.dart:38-55`), timeout điền form nới lên 180s.
- Finding 6.1 (nghi vấn COPPA re-init race làm mất đồng bộ AdMob/AppLovin):
  **FALSE-POSITIVE** (đã xử lý R39/R39v2) — toàn bộ khối COPPA re-init nằm
  trong epoch check (`ad_manager.dart:3960-3990`).

*(Xem ghi chú xác minh chéo ở đầu file — tiêu chí này có 1 MAJOR thật mà báo
cáo gốc của `agy` không phát hiện: GPP "first-non-null-wins" priority order
bỏ sót opt-out thật ở section ưu tiên thấp hơn. Xem `audit_codex.md` R40-02.)*

### Tiêu chí 7: Tuân thủ chính sách chung

- COPPA: AdMob dùng
  `RequestConfigurationTagForChildDirectedTreatment.yes`/`TagForUnderAgeOfConsent.yes`
  (`admob_adapter.dart:800-830`); AppLovin MAX 4.x hardstop khi
  `isAgeRestrictedUser: true` (thiếu runtime child-directed API).
- Gating trước request nghiêm ngặt: `isInitialised && !isVIPMember &&
  consentGranted && isConnected` (`ad_manager.dart:5880-5920`).
- ATT phối hợp với `markUmpFormOnScreen()` tránh chồng dialog
  (`att_consent.dart:20-60`).
- CTR counter tách Fullscreen khỏi Banner/MREC (`ad_manager.dart:4500-4580`).

---

## III. Kết luận và hướng dẫn dành cho nhà phát triển

1. Chất lượng mã nguồn `v2.9.19` đạt tiêu chuẩn cao về quản lý tài nguyên,
   an toàn đa luồng/bất đồng bộ và tuân thủ chính sách quảng cáo trên cả
   Android và iOS.
2. Đối với `IndexedStack` Bottom Navigation: bọc tab bằng
   `Visibility(maintainState: true)` hoặc truyền `active: currentIndex ==
   tabIndex` vào `BannerAdWidget`/`MrecAdWidget`.
3. Đối với VIP Code không server: nếu thương mại hoá với giá trị quy đổi
   cao, cân nhắc bổ sung server xác thực trung tâm chống chia sẻ mã; cho
   mục đích khuyến mãi nội bộ, Ed25519 hiện tại đủ an toàn trước giả mạo.

**ĐÁNH GIÁ CUỐI CÙNG CỦA `agy`: CODE SẴN SÀNG CHO PRODUCTION 100% (APPROVED
FOR PRODUCTION).** — *lưu ý: điểm số và verdict "0 MAJOR mới" ở trên là kết
luận riêng của `agy`, không phải kết luận cuối của phiên audit round 40; xem
`audit_round40_consolidated.md` cho verdict đã hợp nhất cả 3 nguồn.*
