# T68 — `suspiciousViolationCount` trong snapshot/compliance report lag so với decay real-time dùng cho `policyRiskScore`

- **REQ:** audit round mới 2026-08-15 (claude subagent, đã verify độc lập — reframe từ claim gốc sai)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_safety_config.dart:650,740-747`

## Vấn đề (Why)
Verify note: claim gốc "`suspiciousViolationCount` không decay" là **SAI** — counter đã có decay từ T25 (2026-07-09, `_decayViolationCount()`). Gap thật, hẹp hơn: `_decayViolationCount()` chỉ chạy lại mỗi khi CÓ vi phạm mới (gọi trong `_triggerSuspiciousPause`), trong khi `policyRiskScore`'s `violationComponent` tính decay **real-time** mỗi lần gọi (`math.pow(0.5, hoursSince/24)` ngay tại thời điểm đọc, dòng 740-747). `snapshot()`/compliance report đọc raw `_suspiciousViolationCount` (dòng 650) có thể hiện số cũ hơn thực tế nếu đọc giữa 2 lần vi phạm — 2 số liệu tưởng cùng nguồn nhưng lệch độ tươi.

## Đề xuất
Áp dụng phần tính decay tương đương (không tăng counter, chỉ tính lại để hiển thị) trước khi build `snapshot()`/compliance report, để 2 số liệu nhất quán.

## Acceptance criteria
- [ ] Test: đọc `snapshot()` giữa 2 lần vi phạm sau khoảng thời gian dài → `suspiciousViolationCount` hiển thị khớp giá trị đã decay, không phải raw cũ.
