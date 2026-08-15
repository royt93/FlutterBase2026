# T58 — `MonetizationArbitrator` lệch đơn vị x1000 khi tính eCPM

- **REQ:** audit round mới 2026-08-15 (agy, đã verify độc lập — CONFIRMED)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart:106-110,134-148`

## Vấn đề (Why)
`_samples` lưu revenue của **1 impression** (micros, vd $0.005 = 5,000 micros), nhưng `estimatedEcpmMicros` lấy trung bình cộng trực tiếp so với `ecpmThresholdMicros` (định nghĩa cho **1,000** impression, vd $5.00 CPM = 5,000,000 micros) mà không nhân 1000. Ad thật đạt $5 CPM chỉ được tính là $0.005 CPM, luôn dưới ngưỡng → `decide()` coi hầu hết ad là giá trị thấp. `maxVetoRate` guardrail chặn không cho veto 100% (ổn định quanh ~50%) nhưng feature "smart arbitration" vẫn hành xử sai-theo-thiết-kế ở ngưỡng mặc định.

## Đề xuất
Nhân `estimatedEcpmMicros` với 1000 trước khi so ngưỡng (hoặc đổi toàn bộ ngưỡng về đơn vị per-impression, chọn 1 và ghi rõ đơn vị trong dartdoc để tránh lệch lại).

## Acceptance criteria
- [ ] Test: revenue trung bình $0.005/imp ($5 CPM) KHÔNG bị veto ở ngưỡng mặc định $5 CPM.
- [ ] Test: revenue trung bình $0.0005/imp ($0.5 CPM) VẪN bị veto đúng.
- [ ] `flutter test` pass.
