# T127 — Flagship: Self-healing dual-provider runtime (prototype observe-only)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `monetization/fill_rate_monitor.dart`, `fill_rate_baseline_monitor.dart`, `lib/src/core/ad_manager.dart` (chọn adapter theo `AdSlotType`)

## Vấn đề

`AdConfig.provider` hiện cố định 1 provider cho TOÀN BỘ phiên (kể cả sau T90's cohort split). Chưa có cơ chế: nếu riêng 1 ĐỊNH DẠNG của provider chính đang fill-rate tệ (theo dữ liệu `FillRateMonitor`/`FillRateBaselineMonitor` T97 đã thu thập sẵn), tự thử provider còn lại CHỈ cho định dạng đó. [đồng thuận 3 nguồn — mỗi nguồn gọi tên khác nhau, cùng ý tưởng]

## Việc cần làm

- [ ] **Scope round này: OBSERVE-ONLY.** Chỉ LOG quyết định "sẽ chuyển slot X sang provider Y nếu bật thật" — KHÔNG tự động switch provider thật, KHÔNG đổi hành vi ad-serving hiện tại
- [ ] Dùng dữ liệu `FillRateMonitor`/`FillRateBaselineMonitor` đã có, không cần adapter mới nào
- [ ] Ghi lại observe-log vào event stream hiện có (loại event mới, không ảnh hưởng luồng cũ)
- [ ] Test: mô phỏng chuỗi event fill-rate tệ liên tục, xác nhận observe-log ghi đúng khuyến nghị, KHÔNG có side-effect nào lên adapter/slot thật

## Ghi chú

Effort ước lượng lại cho phần OBSERVE-ONLY này: **L** (không phải XL của full feature — full feature cần 2 adapter sống song song 1 phiên, đổi giả định kiến trúc lõi, để dành ticket riêng khi có quyết định bật auto-act thật).
