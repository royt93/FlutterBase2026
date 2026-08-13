# P02 — `AnimatedNumberText`/`AnimatedIntText` không animate

- **Priority:** P1 · **Severity:** HIGH · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/widgets/animated_number_text.dart`, dùng ở `control_panel_widget.dart:324-330,371-378`

## Vấn đề
`Tween<double>(begin: value, end: value)` — `begin` và `end` giống nhau mỗi lần rebuild, nên `TweenAnimationBuilder` không có gì để interpolate, giá trị nhảy tức thì thay vì chạy mượt. So sánh với cách làm đúng ở `speedometer_gauge_widget.dart:50` (không set `begin`, để `TweenAnimationBuilder` tự lấy giá trị cũ làm điểm bắt đầu).

## Bằng chứng
- `widgets/animated_number_text.dart:23` (`AnimatedNumberText`) và `:54` (`AnimatedIntText`).
- Đối chiếu đúng: `speedometer_gauge_widget.dart:50`.
- Ảnh hưởng: hiển thị `average_speed`/`data_downloaded` trong `control_panel_widget.dart:324-330,371-378`.

## Việc cần làm (đề xuất, chưa code)
- Bỏ `begin: value` khỏi `Tween`, để `TweenAnimationBuilder` tự quản lý giá trị bắt đầu từ build trước (giống `speedometer_gauge_widget.dart`).

## Acceptance criteria
- [ ] Số liệu tốc độ/data downloaded chạy animation mượt khi thay đổi, không nhảy số tức thì.
- [ ] Widget test: đổi `value` prop 2 lần liên tiếp, verify animation controller thực sự interpolate (không phải instant jump).
