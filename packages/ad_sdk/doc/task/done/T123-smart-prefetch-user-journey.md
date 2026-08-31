# T123 — Idea: Smart prefetch theo hành trình người dùng

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (batch D, 2026-08-31)
- **Files:** manager load APIs, route observer, ad slot/backoff, safety config

## Vấn đề

Preload hiện chủ yếu theo init/resume/reconnect, chưa biết 1 placement sắp được dùng. [đồng thuận 3 nguồn]

## Việc cần làm

- [x] Host khai báo lightweight signal (string tự do, vd `levelStarted`) qua `notifySignal(signal, type)` + `maxHoldDuration` budget (constructor param)
- [x] SDK học rolling time-to-show on-device (10-sample rolling window per (signal,type)) để preload vừa đủ sớm
- [x] Tự bỏ qua khi VIP/cap/offline/consent đóng — KHÔNG bypass gì cả, `notifySignal` chỉ gọi lại đúng `AdManager().loadX()` công khai, mọi gate hiện có vẫn áp dụng nguyên vẹn
- [x] Test: `test/journey_prefetcher_test.dart` (6 test) — preload lần đầu, ghi nhận rolling average đúng, show thất bại không tính là mẫu, vượt `maxHoldDuration` thì ngừng preload sớm, dispose() dừng ghi nhận

## Đã làm (batch D, 2026-08-31)

`lib/src/monetization/journey_prefetcher.dart` — opt-in qua
`AdManager().enableJourneyPrefetcher(...)`, tự dispose trong
`destroy()`/`_resetGuardState()`, cùng pattern `FillRateMonitor`/
`WaterfallTuner`. Chỉ áp cho 4 format fullscreen (appOpen/interstitial/
rewarded/rewardedInterstitial) — banner/MREC/native là per-widget-instance,
không có 1 slot toàn cục để "prefetch theo signal" áp dụng cùng cách. Không
implement `expectedBreakIn` hint riêng của ticket gốc — rolling average tự
học đủ vai trò đó qua thời gian, thêm tham số tường minh nữa là phức tạp hoá
không cần thiết cho v1.

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/journey_prefetcher_test.dart` — `enableJourneyPrefetcher` thật, gọi `notifySignal()` trên SDK đang chạy. Đã viết, `flutter analyze` sạch, chưa chạy trên thiết bị.
