# T27 — VIP grace-period expiry nudge (`graceNudgeThreshold` + one-time SnackBar)

- **REQ:** 7 (feature idea, round 7 ideation)
- **Priority:** P2 · **Severity:** — · **Status:** ✅ done (2026-07-10, SDK 1.0.24)
- **Files:** `vip/vip_manager.dart` (`graceNudgeThreshold`, `graceNudgeDueListenable`, `acknowledgeGraceNudge()`), `utils/ad_preferences.dart` (persist ack'd expiry), host UI hook

> Ghi chú: task này từng có mặt trong bảng backlog nhưng thiếu file — backfill 2026-07-10 khi rà lại board cho audit toàn diện, nội dung lấy từ `CHANGELOG.md` [1.0.24].

## Vấn đề (Why)
Khi VIP entry sắp hết hạn, user không có cảnh báo trước — ads bật lại đột ngột không báo trước, trải nghiệm xấu, mất cơ hội để user chủ động redeem/gia hạn.

## Giải pháp đã chọn
`VipManager` thêm `graceNudgeThreshold` (mặc định 24h). Khi `expiresAt` của entry đang active vào trong ngưỡng này, `graceNudgeDueListenable` bật `true` để host hiển thị nhắc nhở (SnackBar) mời redeem/gia hạn. `acknowledgeGraceNudge()` lưu lại `expiresAt` hiện tại để không nhắc lại lần 2 cho cùng 1 lần hết hạn — nhưng nếu có gia hạn mới (redeem/watch-ad) đẩy `expiresAt` xa hơn, nudge sẽ due trở lại đúng lúc. Không VIP / không active thì không bao giờ due.

## Acceptance criteria
- [x] Nudge chỉ bật khi còn VIP active và trong ngưỡng `graceNudgeThreshold`.
- [x] Acknowledge xong không nhắc lại cho cùng `expiresAt`.
- [x] Gia hạn mới (stack) làm nudge due lại đúng logic (không bị "khoá" vĩnh viễn bởi ack cũ).

## Test
`test/vip_manager_grace_nudge_test.dart`.

## Kết quả
SDK 1.0.24. `flutter analyze` clean (root + SDK).

## Giới hạn đã biết
Host UI hook (SnackBar hiển thị) là ví dụ tích hợp, không phải UI bắt buộc — mỗi host tự quyết định hiển thị nudge như thế nào, SDK chỉ cung cấp tín hiệu qua listenable.
