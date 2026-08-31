# T122 — Idea: Waterfall tuner on-device theo placement

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `state/ad_event.dart`, compliance log, fill-rate monitors, diagnostics, experiment bucket

## Vấn đề

Event hiện có load latency, fill/revenue/network name nhưng chưa biến chúng thành khuyến nghị cấu hình. [đồng thuận 3 nguồn, effort XL]

## Việc cần làm

- [ ] Lưu rolling score theo provider/format/placement (fill, latency, eCPM)
- [ ] Đưa ra khuyến nghị local "ưu tiên provider X cho placement Y"
- [ ] Chỉ auto-switch tại ranh giới session khi host opt-in, KHÔNG load shadow ad
- [ ] Test: rolling score tính đúng từ chuỗi event mô phỏng, khuyến nghị đúng hướng khi 1 provider rõ ràng tốt hơn

## Ghi chú

Làm sớm, độc lập với FLAGSHIP-A/T127 theo quyết định user — nhưng cân nhắc thiết kế rolling-score chung nếu 2 việc chạy song song để tránh trùng lặp code đo lường fill-rate/latency.
