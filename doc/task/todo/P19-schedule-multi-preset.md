# P19 — Schedule: nhiều preset đặt tên thay vì 1 slot

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/schedule_controller.dart`, `services/schedule_storage.dart`

## Vấn đề / cơ hội
`schedule_controller.dart:107` hiện chỉ support 1 schedule slot. Mở rộng thành nhiều slot đặt tên (VD "Test đêm 2h", "Test giờ nghỉ trưa") với duration/server target riêng cho mỗi slot sẽ hữu ích hơn cho user muốn theo dõi nhiều khung giờ khác nhau.

## Việc cần làm (đề xuất, chưa code)
- Đổi `ScheduleStorage` từ lưu 1 schedule sang `List<Schedule>` (cần model `Schedule` có `name`, `time`, `duration`, `serverTargets`).
- `schedule_screen.dart` cần UI list + thêm/sửa/xoá từng preset.
- Cân nhắc giới hạn số preset tối đa (tránh spam notification).

## Acceptance criteria
- [ ] Tạo được ≥2 preset khác giờ, mỗi preset bắn notification riêng đúng giờ.
- [ ] Migration: schedule cũ (1 slot) không bị mất khi update lên schema mới.
