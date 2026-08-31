# T112 — Enhancement: Nối FillRateBaselineMonitor (T97) làm tín hiệu veto cho MonetizationArbitrator (T99)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/monetization/monetization_arbitrator.dart`, `lib/src/monetization/fill_rate_baseline_monitor.dart`

## Vấn đề

2 tính năng đã có nhưng chưa "nói chuyện" với nhau: `FillRateBaselineMonitor` phát hiện fill-rate/eCPM tụt so baseline 7 ngày; `MonetizationArbitrator.decide()` chỉ so ngưỡng eCPM tuyệt đối tĩnh, không biết phiên này có đang trong giai đoạn regression hay không.

## Việc cần làm

- [ ] Thêm tham số optional `FillRateBaselineMonitor?` vào constructor arbitrator
- [ ] Dùng active alert làm tín hiệu veto bổ sung (opt-in, không đổi hành vi mặc định khi không truyền)
- [ ] Test: có alert active → veto đúng; không truyền monitor → hành vi y hệt cũ
