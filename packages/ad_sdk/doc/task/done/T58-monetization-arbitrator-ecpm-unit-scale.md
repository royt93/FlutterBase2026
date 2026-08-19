# T58 — `MonetizationArbitrator` lệch đơn vị x1000 khi tính eCPM

- **REQ:** audit round mới 2026-08-15 (agy, đã verify độc lập — CONFIRMED)
- **Priority:** P1 · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart:106-113`, `packages/ad_sdk/test/monetization_arbitrator_test.dart`, `packages/ad_sdk/test/ad_diagnostics_test.dart`

## Vấn đề (Why)
`_samples` lưu revenue của **1 impression** (micros, vd $0.005 = 5,000 micros), nhưng `estimatedEcpmMicros` lấy trung bình cộng trực tiếp so với `ecpmThresholdMicros` (định nghĩa cho **1,000** impression, vd $5.00 CPM = 5,000,000 micros) mà không nhân 1000. Ad thật đạt $5 CPM chỉ được tính là $0.005 CPM, luôn dưới ngưỡng → `decide()` coi hầu hết ad là giá trị thấp. `maxVetoRate` guardrail chặn không cho veto 100% (ổn định quanh ~50%) nhưng feature "smart arbitration" vẫn hành xử sai-theo-thiết-kế ở ngưỡng mặc định.

## Đề xuất
Nhân `estimatedEcpmMicros` với 1000 trước khi so ngưỡng (hoặc đổi toàn bộ ngưỡng về đơn vị per-impression, chọn 1 và ghi rõ đơn vị trong dartdoc để tránh lệch lại).

## Acceptance criteria
- [x] Test: revenue trung bình $0.005/imp ($5 CPM) KHÔNG bị veto ở ngưỡng mặc định $5 CPM.
- [x] Test ngược lại (eCPM thấp, well-below-threshold) vẫn bị veto đúng — các test cũ trong nhóm `nudgeVip` đã cover, chỉ cần sửa input về đúng thang per-impression thật.
- [x] `flutter test` pass (704/704).

## Đã verify (2026-08-15, TDD)
Viết 2 test mới trước (`T58 — eCPM unit conversion` group trong `monetization_arbitrator_test.dart`) dùng giá trị per-impression THẬT (5,000 micros/impression = $5 CPM thật), watch RED (`Expected: 5000000, Actual: 5000`) — xác nhận đúng bug agy tìm ra. Fix: nhân `sum * 1000` trong `estimatedEcpmMicros` getter.

Phát hiện thêm khi fix: toàn bộ 9 test cũ trong file test đều dùng giá trị synthetic đã "ở thang eCPM" (vd `_rev(100000)` gọi là "$0.10") thay vì per-impression thật như `AdRevenueEvent.valueMicros` được document — nghĩa là test suite cũ được viết cùng 1 giả định sai như code, nên không bắt được bug. Đã sửa toàn bộ input `_rev()` về đúng thang per-impression (chia 1000), giữ nguyên assertion/comment "$X CPM". 704/704 test pass, `flutter analyze` sạch. Sửa nguồn: `monetization_arbitrator.dart` (1 dòng, +dartdoc); test: `monetization_arbitrator_test.dart` (2 test mới + 17 input chỉnh thang), `ad_diagnostics_test.dart` (1 input chỉnh thang).
