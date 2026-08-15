# T100 — AppLovin `NativeAdWidget` chưa re-check gate khi subtree bị tạo lại (tách từ T62)

- **REQ:** tách từ T62 sau khi T62's root cause thật (deadlock mount) được fix (2026-08-15)
- **Priority:** P2 (giờ mới có ý nghĩa để test, vì trước đây view chưa từng mount lần nào) · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart` (`_allowed`, `build()`)

## Vấn đề (Why, chưa verify — claim gốc của T62 trước khi phát hiện deadlock)
`_allowed` được set `true` một lần qua gate ban đầu (consent/cooldown/cap/network) và không có cơ chế re-check khi widget rebuild sau đó. Trước khi T62 fix xong, câu hỏi này vô nghĩa vì `MaxNativeAdView` chưa từng mount lần nào — giờ view đã mount thật, có thể verify: nếu consent bị revoke/cap đổi trạng thái SAU khi `_allowed=true` và trước khi `MaxNativeAdView` load xong, widget có tạo/giữ view dù gate đã đổi không.

## Việc cần làm
- [ ] Viết test: gate pass → `_allowed=true` → revoke consent / trigger cap TRƯỚC khi `MaxNativeAdView` báo loaded → xác nhận hành vi thật (có tiếp tục hiển thị native view đã mount, hay ẩn/dispose).
- [ ] Nếu xác nhận có vấn đề: thêm re-check gate hoặc ẩn view khi gate đổi giữa chừng.
- [ ] Nếu không tái hiện được / hành vi hiện tại chấp nhận được: đóng ticket, ghi bằng chứng.
