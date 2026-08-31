# T112 — Enhancement: Nối FillRateBaselineMonitor (T97) làm tín hiệu veto cho MonetizationArbitrator (T99)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/monetization/monetization_arbitrator.dart`, `test/monetization_arbitrator_test.dart`

## Vấn đề

2 tính năng đã có nhưng chưa "nói chuyện" với nhau: `FillRateBaselineMonitor` phát hiện fill-rate/eCPM tụt so baseline 7 ngày; `MonetizationArbitrator.decide()` chỉ so ngưỡng eCPM tuyệt đối tĩnh, không biết phiên này có đang trong giai đoạn regression hay không.

## Việc cần làm

- [x] Thêm tham số optional `FillRateBaselineMonitor?` vào constructor arbitrator
- [x] Dùng active alert làm tín hiệu veto bổ sung (opt-in, không đổi hành vi mặc định khi không truyền) — chèn ngay trước guardrail `vetoRate` hiện có nên 1 alert runaway/misconfig vẫn bị guardrail đó chặn như bình thường, không có đường tắt.
- [x] Test (group "T112" trong `monetization_arbitrator_test.dart`): không truyền monitor → `showAd` y hệt cũ; có alert active cho đúng slot → `nudgeVip` dù eCPM heuristic riêng của arbitrator (0 revenue sample) sẽ nói `showAd`; slot khác không regressed không bị ảnh hưởng.
