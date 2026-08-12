# P38 — Rollback schedule khi lỗi không cancel notification đã đăng ký 1 phần

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập, đã verify lại trực tiếp)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/schedule_controller.dart:111-128`

## Vấn đề
Khi `_notifications.scheduleReminder(...)` (dòng 112-116) throw giữa lúc đang đăng ký (VD: đăng ký xong vài weekday alarm thì lỗi ở alarm tiếp theo), catch block (dòng 118-127) chỉ lưu `enabled: false` vào storage, **không gọi `_notifications.cancelReminder()`** để dọn các alarm đã đăng ký thành công trước đó. Kết quả: storage nói "disabled" nhưng OS vẫn có thể còn alarm/notification treo lại từ lần đăng ký lỗi dở đó.

## Bằng chứng
- `schedule_controller.dart:107-110` — nhánh disable gọi `cancelReminder()` đúng.
- `schedule_controller.dart:118-127` — nhánh catch lỗi KHÔNG gọi `cancelReminder()`, chỉ lưu storage.

## Việc cần làm (đề xuất, chưa code)
- Thêm `await _notifications.cancelReminder()` trong catch block trước/sau khi lưu storage, đảm bảo rollback đối xứng với nhánh disable.

## Acceptance criteria
- [ ] Mock `scheduleReminder` throw sau khi đăng ký 1 phần → verify `cancelReminder()` được gọi trong catch.
- [ ] Unit test cover rollback path.
