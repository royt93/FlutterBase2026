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
- [x] Tính năng chỉ khả dụng khi VIP active, tự tắt khi VIP hết hạn (đúng pattern suppress hiện có).
- [x] Biểu đồ xu hướng hiển thị đúng dữ liệu tích lũy qua nhiều tuần.

## Kết quả (2026-08-13)
P18 đã kết luận (batch F) không có native background execution thật — nên
tính năng này rescope đúng theo hướng ticket tự nêu: "chỉ log khi app mở,
không thật chạy nền". Đã implement:

- `presentation/vip_health_monitor_screen.dart` (mới): đọc thẳng
  `HistoryController.allResults` (không đụng `filteredResults`/
  `selectedTimeRange` để tránh side-effect chung với `HistoryScreen`), lọc
  cục bộ theo mốc thời gian tuần này / tuần trước / 30 ngày gần nhất.
  - Card so sánh tuần này vs tuần trước dùng `TestStatistics.fromResults()`
    có sẵn (tránh viết lại thống kê), hiện tăng/giảm/ổn định theo ngưỡng ±5%.
  - Biểu đồ 30 ngày tái dùng thẳng widget `HistoryChart` có sẵn.
- Gate VIP: icon `monitor_heart_outlined` mới trong `wifi_stressor_screen.dart`
  actions, dùng đúng pattern `AdManager().vip` + `ValueListenableBuilder<bool>`
  đã có ở `_buildVipAction()` — ẩn hẳn (`SizedBox.shrink()`) khi VIP null hoặc
  không active, không phải chỉ disable.
- i18n: `vip_health_monitor_*` (vi/en).

ponytail: không viết background scheduler/log job mới — dùng thẳng lịch sử
test đã lưu (dù chạy tay hay qua P18 auto-run) làm nguồn dữ liệu xu hướng.
Đúng phạm vi rescope ticket đã tự lường trước, không phải cắt giảm phát sinh.
