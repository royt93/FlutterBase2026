# SDK Backlog — round 27 roadmap (2026-08-31)

Nguồn: 3 agent độc lập đọc toàn bộ `packages/ad_sdk/lib/` + `example/` sau
round-26 audit (baseline: `applovin_admob_sdk` 2.4.2, 3/3 finding round-26 còn
mở đã fix trong phiên này — xem `audit_round26_consolidated.md`). Báo cáo gốc:
`PROPOSALS-codex-2026-08-31.md`, `PROPOSALS-agy-2026-08-31.md`,
`PROPOSALS-claude-2026-08-31.md`.

Mục **[đồng thuận]** = ≥2 nguồn độc lập tìm thấy cùng vị trí — độ tin cậy cao
hơn. Mục **[verified]** = tôi (phiên chính) đã tự đọc lại source xác nhận
đúng, không chỉ tin báo cáo.

---

## 1. BUG cần fix

**B1, B4, B5, B6, B7 — FIXED 2026-08-31 (round 27, version 2.4.3).** Mỗi cái
mutation-verified (revert→red→fix→green) trừ B5 (xem ghi chú riêng), full
suite 1347 test pass, `flutter analyze` sạch.

| # | Bug | Nguồn | Sev | Effort | Trạng thái |
|---|---|---|---|---|---|
| B1 | **[verified] `pickProviderCohort()`/`experimentBucket()` sập về 1 bucket duy nhất cho MỌI thiết bị** khi gọi đúng thứ tự chính README/docstring dạy (trước `initialize()`) — `AdPreferences.instanceOrNull` là `null`, GAID chưa fetch (`''`), `installId` luôn `''`. Toàn bộ tính năng A/B provider-split (T90/T93) không hoạt động, không có warning nào. Test hiện có vô tình che bug vì luôn gọi `AdPreferences.getInstance()` trong `setUp()` trước khi test. `ad_manager.dart:371-378`, `ad_preferences.dart:21,34,347`. | claude | **P0** | M | **FIXED** — mint 1 id ngẫu nhiên trong RAM ngay khi cần trước bootstrap (ổn định suốt tiến trình, không rơi về `''`), seed lại vào `AdPreferences` ngay khi nó bootstrap xong để ổn định qua các lần khởi động sau (`AdPreferences.seedExperimentInstallIdIfAbsent`). `experimentBucket()`/`pickProviderCohort()` giữ nguyên đồng bộ, không breaking change. |
| B2 | **[đồng thuận — codex+agy] `FillRateBaselineMonitor`/`recordFillRateBaselineSample` ghi không tuần tự (`unawaited`)** — 2 event load/revenue sát nhau cùng đọc snapshot JSON cũ, ghi sau cùng làm mất delta của ghi kia. Baseline 7 ngày (T97) sai/thấp, cảnh báo regression sai theo đó. `fill_rate_baseline_monitor.dart`, `ad_preferences.dart`. | codex, agy | P1 | M | → tách **T101** — **FIXED (2.4.4)**, write chained qua `_fillRateBaselineChain` |
| B3 | **[đồng thuận — codex+agy] `_eventLog.flush()` không được await trước khi null hoá trong `destroy()`** — `initialize()` sau đó có thể tạo log mới trước khi flush cũ ghi xong, 2 session ghi đè event của nhau ở đúng ranh giới lifecycle nhạy cảm nhất. Ảnh hưởng compliance report/signing (T96). `ad_manager.dart` (cuối `_destroy`), `ad_event_log.dart`. | codex, agy | P1 | M | mở — effort M, để lại backlog → tách **T102** |
| B4 | **[đồng thuận — codex+agy] `TopToast`: toast cũ có thể dismiss/ghi đè toast mới** — `Future.delayed` không cancel được, timer của toast A vẫn chạy và remove `_current` đang là toast B. `top_toast.dart`. | codex, agy | P2 | S | **FIXED** — `Future.delayed` → `Timer` (cancel trong `dispose()`) + dismiss theo identity (`_dismissIfCurrent`, chỉ remove nếu entry vẫn là `_current`). Mutation-verified: `test/top_toast_test.dart`. |
| B5 | **[đồng thuận — codex+agy] Example app: `EventBuffer` chết sau `AdManager().destroy()`** — subscribe 1 lần trong `main()`, `destroy()` tạo stream controller mới nên subscription cũ nhận `done` và không theo stream mới. Demo "Event stream" âm thầm sai sau destroy/reinit. `example/lib/main.dart`. | codex, agy | P2 | S | **FIXED** — re-subscribe theo `AdManager().initRevision` (đã dùng cho mục đích tương tự nơi khác trong example). `flutter analyze` example sạch; KHÔNG có unit/integration test tự động chứng minh (example không có unit test harness cho phần này, viết integration test mới cần emulator — để dành nếu cần). |
| B6 | **`installAdCrashGuard()` không idempotent — leak tuyến tính theo số lần init/destroy.** Mỗi `initialize()` với `enableCrashGuard: true` bọc thêm 1 lớp closure quanh `FlutterError.onError`, không có cờ "đã cài", `destroy()` không gỡ. App đổi provider/logout-login nhiều lần trong 1 phiên sống dài → crash bị xử lý N lần, chuỗi closure cũ không GC được. `ad_crash_guard.dart:58-85`. | claude | P1 | S | **FIXED** — theo dõi identity của handler đã cài (`_installedOnError`/`_installedOnPlatformError`) thay vì cờ `bool`; no-op nếu handler hiện tại vẫn đúng cái mình cài, nhưng VẪN cài lại nếu có gì khác đã thay handler (không silently mất guard). Mutation-verified: `test/ad_crash_guard_test.dart` (2 test mới). |
| B7 | **Reinit-without-destroy() không dọn `_consentDialogTimer`/`_consentDialogScheduled`** — round-26 chỉ vá nhánh `destroy()`, `_resetGuardState()` (single-source-of-truth cho guard flag theo đúng comment của chính nó) không đụng 2 field này. Cùng họ bug với round-26 #4, khác đường vào (host gọi `initialize()` lần 2 không qua `destroy()` — pattern được chính code hỗ trợ). `ad_manager.dart:1603-1659` vs `:5065-5150`. | claude | P1 | S | **FIXED** — chuyển 2 dòng cleanup từ `destroy()` vào `_resetGuardState()`, cả 2 đường vào giờ dọn qua đúng 1 hàm. Mutation-verified: `test/ad_manager_core_test.dart` (test seam mới `debugConsentDialogTimerActive`). |
| B8 | Splash ví dụ (`example/lib/main.dart _SplashScreenState`) ghi `ValueNotifier` đã dispose khi callback ad-load native trả về trễ sau khi widget dispose — implementation riêng của example, khác `AdReadinessSplashController` đã fix ở round-26. | codex | P1 | S | **FIXED** (T103, 2.4.5) |
| B9 | `AppLovinAdapter._disposedNativeKeys` (tombstone Set) phình vô hạn với native ad trong feed cuộn dài — key chỉ được gỡ khi đúng widget cũ mount lại, native ad cuộn qua vĩnh viễn thì rò rỉ tuyến tính theo session. `applovin_adapter.dart:487-545`. | claude | P2 | M | **FIXED** (T104, 2.4.5) |
| B10 | Thiếu guard `identical(...)` đối xứng trên `onAdOpened`/`onAdClicked` (cả 2 adapter, round-26 #2 chỉ nêu `onFailed`) + `eventSink` không null hoá ở AppLovin `dispose()` — click/open trễ sau dispose vẫn ghi vào CTR-fraud counter, làm nhiễu chính tầng anti-fraud. | claude | P2 | M | **FIXED** (T105, 2.4.5) |

## 2. ENHANCEMENT

Cả 3 nguồn hội tụ mạnh vào cùng nhóm ý tưởng — gộp, không lặp:

- **ENH-1 — Bootstrap API 1 hàm** cho ATT→UMP→initialize→splash (giảm boilerplate/footgun tích hợp đầu tiên). *[đồng thuận 3 nguồn]* → tách **T106**
- **ENH-2 — `AdPlacement` typed xuyên suốt** load/show/widget thay vì string rải rác. *[đồng thuận 3 nguồn]* → tách **T107**
- **ENH-3 — Retry policy cấu hình theo format + loại lỗi** (no-fill/network/invalid-request/timeout khác nhau, hiện dùng 1 `Backoff` chung). *[đồng thuận 3 nguồn]* → tách **T108**
- **ENH-4 — `AdSdkStateSnapshot`**: 1 `ValueListenable` tổng hợp init/consent/offline/VIP/fullscreen-busy/slot state, thay việc host phải ghép nhiều notifier riêng. *[đồng thuận 3 nguồn]* → tách **T109**
- **ENH-5 — Redaction profile cho compliance/diagnostics export** (host tự chọn field nhạy cảm nào được gửi support). *[đồng thuận 2 nguồn]* → tách **T110** — **FIXED (2.5.0)**
- **ENH-6 — `RemoteAdSafetyProvider` không có đường re-fetch định kỳ** — hiện phải `destroy()`+`initialize()` lại toàn bộ để áp remote config mới, mất hết lợi ích "remote" so với `refreshRevocationList()` (T95) đã có pattern đúng. (claude) → tách **T111**
- **ENH-7 — Nối `FillRateBaselineMonitor` (T97) làm tín hiệu veto cho `MonetizationArbitrator` (T99)** — 2 tính năng có sẵn nhưng chưa "nói chuyện" với nhau. (claude) → tách **T112** — **FIXED (2.5.0)**
- **ENH-8 — `AdPlacement` không dùng được trong `const` map** (giới hạn Dart, T92 tự ghi nhận) — thêm `AdPlacement.id(String)` né tránh. (claude) → tách **T113** — **FIXED (2.5.0)**, dùng `maxPerPlacementAdsPerDayById: Map<String,int>` thay vì constructor `.id()` mới (giới hạn Dart thật, không constructor nào né được)
## 3. TECH DEBT

- **DEBT-1 — Tách `AdManager` ~7000 dòng** thành internal coordinators (Init/Consent/Lifecycle/Fullscreen/Retry) — 0 đổi hành vi, giảm blast-radius mỗi lần audit/fix. *[đồng thuận 3 nguồn]* — Effort XL, rủi ro nếu làm vội. → **user quyết định bỏ qua hẳn, không tạo ticket** (round 27, 2026-08-31).
- **DEBT-2 — Hợp nhất lifecycle keyed inline-ad giữa 2 adapter** (map instance/dispose/revive lặp lại, chính là lý do B10 tồn tại — fix 1 bên quên bên kia). *[đồng thuận 3 nguồn]* → tách **T114**
- **DEBT-3 — Chuẩn hoá primitive hủy callback async** (generation/bool-disposed/timer/Completer trộn lẫn tuỳ nơi). *[đồng thuận 3 nguồn]* → tách **T115**
- **DEBT-4 — Contract-test chung cho `AdProviderAdapter`** — parity 2 adapter hiện chỉ được assert rải rác theo file riêng. *[đồng thuận 3 nguồn]* → tách **T116**
- **DEBT-5 — Chia `example/lib/main.dart` (~2700 dòng)** theo từng demo/module — dễ đọc như cookbook. *[đồng thuận 2 nguồn]* → tách **T117**
## 4. Ý TƯỞNG MỚI (không cần backend)

- **IDEA-1 — `FakeAdProviderAdapter`**: adapter thứ 3 hoàn toàn offline (không network, không ad-unit ID thật) cho CI/demo/App-Review build — giải đúng nỗi đau CI hiện tại phải force AdMob vì thiếu key AppLovin thật. (claude, cụ thể + rẻ) → tách **T118**
- **IDEA-2 — `AdManager().explainLastSkip(AdSlotType)`**: ring buffer nhỏ trả lời "ad không hiện, tại sao?" — nhẹ hơn compliance report, đúng câu hỏi hỗ trợ phổ biến nhất. (claude) → tách **T119** — **FIXED (2.5.0)**
- **IDEA-3 — Bộ mô phỏng ma trận consent** (`simulateConsentOutcome`) — pure function, QA xem trước AdMob/AppLovin sẽ nhận gì cho từng tổ hợp GDPR/ATT/COPPA, không cần build lên máy thật. (claude) → tách **T120** — **FIXED (2.5.0)**
- **IDEA-4 — Ramp an toàn cục bộ theo tuổi install** (D0/D3/D7/D30 → `AdSafetyParams` khác nhau, hoàn toàn local, dùng `firstInstallAtMs` đã có) — bổ sung "no-server" cho T88. (claude) → tách **T121**
- **IDEA-5 — Waterfall tuner on-device theo placement** — rolling score fill/latency/eCPM, khuyến nghị "ưu tiên provider X cho placement Y", chỉ auto-switch khi host opt-in. *[đồng thuận 3 nguồn]* → tách **T122**
- **IDEA-6 — Smart prefetch theo hành trình người dùng** (host khai báo signal `levelStarted`/`screenEntered`, SDK học rolling time-to-show). *[đồng thuận 3 nguồn]* → tách **T123**
- **IDEA-7 — `AdaptiveAdSurface`**: 1 widget tự chọn banner/MREC/native theo width/orientation. *[đồng thuận 3 nguồn]* → tách **T124**
- **IDEA-8 — Offline incident recorder + replayable support bundle** — ring buffer state-transition timeline, ký + replay local, giảm thời gian support bug chỉ tái hiện trên 1 máy. *[đồng thuận 3 nguồn]* → tách **T125**
- **IDEA-9 — Creative fatigue guard on-device** — cooldown network/creative lặp quá dày (fail-open nếu thiếu metadata). *[đồng thuận 3 nguồn]* → tách **T126**
## 5. TÍNH NĂNG ĐỘC QUYỀN / FLAGSHIP

Cả 3 nguồn **độc lập hội tụ vào đúng 2 hướng** — tín hiệu rất mạnh đây là hướng
differentiator đúng:

- **FLAGSHIP-A — Self-healing dual-provider runtime.** State machine on-device
  phát hiện 1 định dạng/provider đang fill-rate tệ (dữ liệu `FillRateMonitor`/
  baseline T97 đã có sẵn) → tự thử provider còn lại CHỈ cho định dạng đó,
  không phải chuyển cả phiên như T90. *[đồng thuận 3 nguồn]*. Effort XL — cần
  2 adapter sống song song 1 phiên (đổi giả định kiến trúc hiện tại), nên bắt
  đầu ở "observe-only" trước khi auto-act. → tách **T127**
- **FLAGSHIP-B — Proof-of-compliance / audit trail ký số cho MỌI lần bypass
  safety** (`bypassSafety`, `bypassVipGuard`, `dryRun`) — tái dùng hạ tầng
  Ed25519 đã có cho VIP/CRL/compliance-report (T18/T95/T96), trả lời câu hỏi
  "làm sao chứng minh không ai âm thầm patch quanh safety layer để farm
  doanh thu". *[đồng thuận 3 nguồn, mỗi nguồn đặt tên khác nhau nhưng cùng ý:
  "Offline Policy Autopilot" (codex), "Proof-of-Compliance Engine" (agy),
  "Nhật ký kiểm toán ký số cho bypass" (claude)]*. → tách **T128**
- **FLAGSHIP-C — Monetization Digital Twin** — mô phỏng tác động cap/retry/
  VIP-duration/preload từ event history local, trả dự báo khoảng-tin-cậy
  impression/revenue, không phát ad thử, "shadow mode" trước khi host bật
  thật. *[đồng thuận 3 nguồn]*. → tách **T129**
- **FLAGSHIP-D — Token chuyển VIP sang máy mới** (ký Ed25519 offline, 1 lần
  dùng) — biến giới hạn đã document (Android anti-bypass yếu, đổi máy mất
  VIP) thành tính năng cho user hợp pháp mà không làm yếu anti-abuse. (claude,
  không trùng nguồn khác) → tách **T130**
## Gợi ý thứ tự (không ràng buộc — chờ user chọn)

1. **B1 trước hết** — P0, đã verify, im lặng vô hiệu hoá 1 feature đã ship.
2. B6, B7 (rẻ, S effort, cùng họ round-26 vừa vá).
3. B2, B3 (đồng thuận 2 nguồn, ảnh hưởng tới flagship đã có T96/T97).
4. Phần còn lại của BUG theo P-level.
5. Enhancement/tech-debt/idea/flagship — cần quyết định hướng sản phẩm, để
   user chọn qua câu hỏi trực tiếp.
