# T52 — `AdKey.adMob` (host app) fallback không rõ có dùng hay "quả bom hẹn giờ"

- **REQ:** phát hiện qua audit round 8 (2026-07-19), finding N3
- **Priority:** P3 (Low) · **Status:** ✅ done — verified, giữ nguyên có chủ đích (2026-07-20)
- **Files:** (chỉ đọc, không sửa) `lib/mckimquyen/.../ad_key.dart` (host)

## Vấn đề (Why)
`AdKey.adMob` là fallback config test-ID không thấy được dùng ở call site hiện tại — nghi ngờ là dead config có thể gây nhầm lẫn nếu ai đó đổi provider mà không update.

## Kết luận
Đọc lại toàn bộ call site: đây là config "sẵn sàng đổi provider" có TODO cảnh báo rõ ràng, không phải bug bị quên. Giữ nguyên — xoá sẽ làm khó đổi provider sau này; thêm runtime assert là over-engineering cho 1 giá trị test-ID tĩnh không đổi ngoài ý muốn.

## Acceptance criteria
- [x] Xác nhận có/không dùng ở runtime hiện tại (không dùng — đúng như audit ghi nhận).
- [x] Quyết định rõ ràng: giữ hay xoá, có lý do.

## Đã verify (2026-07-20)
Không sửa code. Xem `doc/audit/audit_claude.md` round 9.
