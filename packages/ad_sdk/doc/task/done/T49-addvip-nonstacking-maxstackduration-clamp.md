# T49 — `VipManager.addVip(stack: false)` thiếu clamp `maxStackDuration`

- **REQ:** phát hiện qua audit round 6 (2026-07-19), mục "Re-audit vòng 6"
- **Priority:** P3 (Low, chưa exploitable) · **Status:** ✅ done (2026-07-19)
- **Files:** `packages/ad_sdk/lib/src/vip/vip_manager.dart`, `packages/ad_sdk/test/vip_manager_stacking_test.dart`, `packages/ad_sdk/test/vip_manager_robustness_test.dart`

## Vấn đề (Why)
Nhánh `stack: true` của `addVip()` clamp tổng thời hạn về `maxStackDuration` (mặc định ~90 ngày). Nhánh `stack: false` (mặc định, "latest expiry wins") không có clamp tương tự — một lời gọi `addVip(duration: ...)` với `duration` tự nó đã vượt cap (ví dụ do lỗi cấu hình hoặc key ký sai) sẽ set `expiresAt` vượt xa giới hạn thiết kế. Không exploitable ở production vì call site sản xuất duy nhất (`vip_redeem_screen.dart:263`) luôn dùng `stack: true`, nhưng là gap defense-in-depth.

## Đề xuất
Thêm cùng logic clamp `maxStackDuration` vào nhánh `stack: false`, đối xứng với nhánh `stack: true`.

## Acceptance criteria
- [x] Nhánh `stack: false` clamp `now + duration` về `now + maxStackDuration` khi vượt cap.
- [x] Test mới xác nhận hành vi (không phải chỉ test riêng lẻ mà còn sửa 1 test cũ đã lock hành vi bug).
- [x] `flutter test` (packages/ad_sdk) pass toàn bộ, không regression.

## Đã verify (2026-07-19)
Sửa `vip_manager.dart` thêm clamp cho nhánh `stack: false`. Test cũ trong `vip_manager_robustness_test.dart` (group `maxStackDuration cap scope`) trước đó đã lock cứng đúng hành vi bug (uncapped) — đổi tên + sửa assertion sang hành vi đã fix ("T49: non-stacking grants ARE ALSO capped by maxStackDuration"). Thêm test bổ sung trong `vip_manager_stacking_test.dart`. `flutter test` (packages/ad_sdk): 644/644 pass, không regression.
