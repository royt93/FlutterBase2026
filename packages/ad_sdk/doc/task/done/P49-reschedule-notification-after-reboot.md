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

## Kết quả (2026-08-13)
Đã verify: **không cần code thêm**. `android/app/src/main/AndroidManifest.xml` (dòng ~120-147) đã có
sẵn `ScheduledNotificationBootReceiver` do package `flutter_local_notifications` tự đăng ký, lắng
`BOOT_COMPLETED`/`MY_PACKAGE_REPLACED`/`QUICKBOOT_POWERON`, cộng permission `RECEIVE_BOOT_COMPLETED`
(dòng 12). Receiver này tự đọc lại pending notification đã lưu (bao gồm các `zonedSchedule` do
`NotificationService.scheduleReminder` tạo) và đăng ký lại alarm — hành vi built-in của plugin, không
cần `ScheduleStorage` tự re-register thủ công.

ponytail: chưa verify bằng reboot thiết bị thật (không có hardware trong môi trường này) — nếu về sau
phát hiện notification không bắn sau reboot thật, điểm cần soi trước tiên là version
`flutter_local_notifications` hiện dùng có regression ở receiver này, chứ không phải thiếu code app.
