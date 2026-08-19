# P18 — Schedule: tự chạy test nền thay vì chỉ nhắc nhở

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** agy CLI + claude CLI
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/schedule_screen.dart`, `services/notification_service.dart`, `controllers/schedule_controller.dart`

## Vấn đề / cơ hội
`schedule_screen.dart` hiện chỉ là reminder (tự confirm hạn chế này bằng disclaimer ngay trong screen) — không tự chạy test nền, user phải mở app thủ công khi có notification. Đây là feature gap tự thừa nhận trong code, hợp lý để làm task kế tiếp.

## Việc cần làm (đề xuất, chưa code)
- Nghiên cứu khả thi background execution trên Android/iOS cho việc chạy stress test thật (Dio download) khi app không foreground — cần đánh giá kỹ giới hạn platform (iOS background task rất hạn chế, Android cần foreground service hoặc WorkManager).
- Nếu không khả thi native background: cân nhắc phương án trung gian — khi user mở app từ notification, tự động bắt đầu test ngay (one-tap) thay vì phải chạm thêm.
- Đây là task lớn, cần thiết kế riêng trước khi ước lượng effort — không nên bắt đầu code ngay khi chưa rõ giới hạn platform.

## Acceptance criteria
- [x] Có kết luận rõ ràng về khả thi background execution trên cả Android + iOS trước khi implement.
- [ ] Nếu khả thi: test tự chạy đúng giờ đã lên lịch, kết quả lưu vào history như test thủ công.
- [x] Nếu không khả thi: implement phương án one-tap-run từ notification thay thế.

## Kết quả (2026-08-13)
Kết luận: background execution thật (chạy Dio download khi app đóng) không khả thi đáng tin cậy
trên cả 2 platform (iOS gần như chặn hoàn toàn, Android cần foreground service riêng — quá tốn
kém cho 1 tính năng nhắc lịch). Đã implement phương án one-tap thay thế: `NotificationService`
có cờ `_pendingAutoRun` set khi user tap notification (cả cold-launch qua `splash_screen.dart`
lẫn warm qua `main.dart`'s `onNotificationTapped`), `wifi_stressor_screen.dart`'s `initState`
đọc + reset cờ này (`consumePendingAutoRun`) và tự gọi `controller.startStressTest()` nếu true.
