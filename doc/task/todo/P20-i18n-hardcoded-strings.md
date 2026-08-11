# P20 — Dọn string hardcode tiếng Anh chưa qua `.tr`

- **Priority:** P2 · **Severity:** LOW · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** claude CLI, subagent (2 subagent khác nhau, mỗi bên tìm ra vị trí khác nhau — cùng pattern)
- **Files:** xem danh sách dưới

## Vấn đề
App có locale mặc định `vi_VN`, translation 2 file `en_us.dart`/`vi_vn.dart` đủ 250 key khớp nhau (đã verify sạch, không thiếu key) — nhưng nhiều đoạn text vẫn hardcode tiếng Anh trực tiếp trong code, không qua `.tr`:
- `test_detail_screen.dart:516-579` (`_shareResult()`) — toàn bộ text share ("📊 WiFi Speed Test Results", "⚡ Performance Statistics:"...) hardcode tiếng Anh.
- `control_button_widget.dart:67` — text disclosure quảng cáo (`adMayAppearEn`) hardcode, không qua `.tr`.
- `splash_screen.dart:457` — title `'FastNet\nSpeed Test'` hardcode, trong khi key `app_title` (đã có sẵn trong `en_us.dart`) đang chỉ dùng ở nơi khác, không dùng ở đây.

## Bổ sung (2026-08-11, audit vòng 2 — subagent đọc source)
Thêm 1 vị trí: `widgets/room_tag_bottom_sheet.dart` — danh sách preset room tag hardcode tiếng Anh/Việt trực tiếp trong code, không có key `.tr` nào (0 key liên quan trong `en_us.dart`/`vi_vn.dart`).

## Việc cần làm (đề xuất, chưa code)
- Thêm key translation cho nội dung `_shareResult()` (cả `en_us.dart` và `vi_vn.dart`), đổi sang `.tr`.
- Đổi `control_button_widget.dart:67` sang key `.tr` có sẵn hoặc tạo mới.
- Đổi `splash_screen.dart:457` dùng key `app_title` đã tồn tại sẵn.
- Sau khi sửa 3 chỗ trên, grep lại toàn `lib/mckimquyen/` tìm string literal tiếng Anh dài (>3 từ) trong `Text(...)`/return string để đảm bảo không sót thêm.

## Acceptance criteria
- [ ] 3 vị trí trên hiển thị đúng tiếng Việt khi locale là `vi_VN`.
- [ ] Không còn string UI-facing hardcode tiếng Anh nào ngoài các exception đã biết (VD literal kỹ thuật, log).
