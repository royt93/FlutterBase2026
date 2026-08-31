# T129 — Flagship: Monetization Digital Twin

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** compliance event log, adaptive frequency, monetization arbitrator, fill-rate baseline, experiment bucket, diagnostics/export tool

## Vấn đề

Mô phỏng trước tác động của cap, retry, provider split, VIP duration và preload policy từ event history local, trả dự báo dạng khoảng-tin-cậy về impression/revenue/blocked-request/UX cost, không phát ad thử. [đồng thuận 3 nguồn, effort XL]

## Việc cần làm

- [ ] Deterministic replay + counterfactual rules trên ring buffer đã redact
- [ ] "Shadow decision mode": chỉ ghi SDK SẼ làm gì, không thay hành vi production tới khi host bật
- [ ] Không phát thêm ad request chỉ để đo lường
- [ ] Test: replay 1 chuỗi event lịch sử với 2 policy khác nhau, xác nhận dự báo khác nhau đúng hướng kỳ vọng

## Ghi chú

Làm sớm, ĐỘC LẬP với T127 (FLAGSHIP self-healing) theo quyết định user — dù BACKLOG doc gốc đề xuất nên làm sau để tránh trùng lặp. Nếu cả 2 chạy song song, cân nhắc thống nhất sớm cấu trúc dữ liệu rolling-metrics dùng chung.
