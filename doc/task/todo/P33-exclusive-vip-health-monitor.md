# P33 — Tính năng độc quyền: VIP Network Health Monitor (theo dõi dài hạn)

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập, agy CLI đề xuất biến thể tương tự dạng "SLA Compliance Certificate")
- **Files liên quan (đã có sẵn):** `schedule_controller.dart`, `services/notification_service.dart`, hạ tầng VIP (`AdManager().vip`)

## Ý tưởng
Nâng cấp hạ tầng schedule/notification đã có thành tính năng **VIP-only**: tự động test định kỳ nền (phụ thuộc P18 giải quyết được background execution), log vào Hive, cho ra biểu đồ xu hướng dài hạn (tuần/tháng). Differentiator vì mọi speed-test app đối thủ đều single-shot, không app nào giữ lịch sử dài hạn kèm phân tích xu hướng — đây cũng là 1 lý do hợp lý để nâng cấp VIP (giá trị thêm ngoài "tắt ads").

## Việc cần làm (đề xuất, chưa code — phụ thuộc P18)
- Chỉ làm sau khi P18 (background auto-run) có kết luận khả thi — nếu P18 không khả thi native background, tính năng này cần scope lại (VD: chỉ log khi app mở, không thật "chạy nền").
- Gate tính năng bằng `AdManager().vip!.activeListenable` (pattern đã dùng ở `wifi_stressor_screen.dart:162`).
- Thiết kế màn hình biểu đồ xu hướng tuần/tháng (tái dùng chart component từ `benchmark_screen.dart`/`comparison_screen.dart`).

## Acceptance criteria
- [ ] Tính năng chỉ khả dụng khi VIP active, tự tắt khi VIP hết hạn (đúng pattern suppress hiện có).
- [ ] Biểu đồ xu hướng hiển thị đúng dữ liệu tích lũy qua nhiều tuần.
