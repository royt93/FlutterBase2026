# P49 — Đăng ký lại schedule notification sau khi thiết bị reboot

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/notification_service.dart`, Android `BOOT_COMPLETED` receiver (chưa có)

## Vấn đề / cơ hội
Chưa xác nhận rõ hành vi hiện tại của `flutter_local_notifications`/plugin thông báo đang dùng có tự khôi phục alarm sau khi reboot hay không (cần đọc kỹ plugin cụ thể trước khi code — agy CLI chỉ nêu ý tưởng, chưa verify hành vi thật). Nếu không tự khôi phục, schedule đã set sẽ mất sau khi user restart máy.

## Việc cần làm (đề xuất — cần verify hành vi plugin trước khi code)
- Kiểm tra doc của plugin notification đang dùng (`android/app/src/main/AndroidManifest.xml` có receiver `BOOT_COMPLETED` chưa?).
- Nếu chưa tự khôi phục: thêm receiver Android, gọi lại `ScheduleStorage` để re-register khi máy khởi động lại.

## Acceptance criteria
- [ ] Xác nhận rõ hành vi hiện tại (có mất schedule sau reboot hay không) trước khi quyết định có cần code hay không.
- [ ] Nếu cần: reboot thiết bị test thật, verify schedule vẫn bắn đúng giờ sau khi khôi phục.
