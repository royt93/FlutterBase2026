# T127 — Flagship: Self-healing dual-provider runtime (prototype observe-only)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/monetization/self_healing_observer.dart` (mới, tái dùng `WaterfallTuner` T122), `lib/src/state/ad_event.dart` (`AdSelfHealingObserveEvent`), `lib/src/core/ad_manager.dart` (`enableSelfHealingObserver` seam), `test/self_healing_observer_test.dart`

## Vấn đề

`AdConfig.provider` hiện cố định 1 provider cho TOÀN BỘ phiên (kể cả sau T90's cohort split). Chưa có cơ chế: nếu riêng 1 ĐỊNH DẠNG của provider chính đang fill-rate tệ (theo dữ liệu `FillRateMonitor`/`FillRateBaselineMonitor` T97 đã thu thập sẵn), tự thử provider còn lại CHỈ cho định dạng đó. [đồng thuận 3 nguồn — mỗi nguồn gọi tên khác nhau, cùng ý tưởng]

## Việc cần làm

- [x] **Scope round này: OBSERVE-ONLY.** `SelfHealingObserver` chỉ emit `AdSelfHealingObserveEvent` lên `AdManager().events` — KHÔNG tự switch provider, KHÔNG đổi hành vi ad-serving.
- [x] Tái dùng `WaterfallTuner` (T122) làm engine điểm fill-rate×eCPM — không viết lại scoring, không adapter mới nào.
- [x] `AdSelfHealingObserveEvent` (subtype `AdEvent` mới) lên đúng stream `AdManager().events` hiện có — listener cũ pattern-match theo type cụ thể không bị ảnh hưởng.
- [x] Test (`test/self_healing_observer_test.dart`, 3 case): mô phỏng chuỗi event fill-rate tệ liên tục → emit đúng 1 lần đúng khuyến nghị; không adapter → không emit gì (fail-safe); không đổi `AdManager().adapter` (side-effect = 0 lên adapter/slot thật); không spam lặp lại cùng 1 khuyến nghị.

## Ghi chú

Effort ước lượng lại cho phần OBSERVE-ONLY này: **L** (không phải XL của full feature — full feature cần 2 adapter sống song song 1 phiên, đổi giả định kiến trúc lõi, để dành ticket riêng khi có quyết định bật auto-act thật).

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/self_healing_observer_test.dart` — `enableSelfHealingObserver` thật, xác nhận provider KHÔNG tự đổi (đúng observe-only). Đã viết, `flutter analyze` sạch, chưa chạy trên thiết bị.
