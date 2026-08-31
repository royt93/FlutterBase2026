# T101 — FillRateBaselineMonitor ghi baseline không tuần tự, mất delta

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `lib/src/monetization/fill_rate_baseline_monitor.dart`, `lib/src/utils/ad_preferences.dart`

## Vấn đề

`recordFillRateBaselineSample()` được gọi bằng `unawaited`. Mỗi lần ghi đọc toàn bộ JSON, cộng delta rồi ghi lại. Hai event load/revenue sát nhau có thể cùng đọc snapshot cũ, ghi hoàn tất sau cùng làm mất delta của ghi kia. Baseline 7 ngày (T97) vì vậy thấp/sai, kéo theo cảnh báo regression sai. [đồng thuận — codex+agy]

## Việc cần làm

- [ ] Thêm write-chain/mutex theo instance hoặc API cộng dồn theo batch
- [ ] Chờ flush khi disable/destroy
- [ ] Test: 2 write bị chủ động đảo thứ tự completion, xác nhận không mất delta
