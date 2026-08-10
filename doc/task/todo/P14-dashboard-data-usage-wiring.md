# P14 — Nối `totalBytesIncludingProgress` vào Network Dashboard

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** claude CLI + subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/stressor_controller.dart`, `lib/mckimquyen/widget/wifi_stressor/presentation/network_dashboard_screen.dart`, `network_dashboard_controller.dart`

## Vấn đề
`totalBytesIncludingProgress` đã tồn tại sẵn ở `stressor_controller.dart:57` (tổng data đã tải qua các lần test), nhưng `network_dashboard_controller.dart` không đọc field này — dashboard không hiển thị được "bạn đã dùng bao nhiêu data qua các lần test". 2 khái niệm "usage" (stressor vs dashboard) đang tách rời không cần thiết, dữ liệu đã có sẵn chỉ cần đọc.

## Việc cần làm (đề xuất, chưa code)
- `NetworkDashboardController` đọc `totalBytesIncludingProgress` (hoặc tổng cộng dồn từ `TestHistoryStorage` nếu cần số liệu lịch sử, không chỉ session hiện tại) và hiển thị 1 card "Data đã dùng để test" trong `network_dashboard_screen.dart`.
- Quyết định scope: chỉ session hiện tại, hay tổng cộng dồn mọi lần test lịch sử (khuyến nghị: tổng cộng dồn, hữu ích hơn và là tiền đề cho P25 idea "data-budget tracker").

## Acceptance criteria
- [ ] Dashboard hiển thị tổng data đã tiêu tốn qua test, số liệu khớp với tổng thực tế trong Hive history.
- [ ] Widget test verify card hiển thị đúng khi có N test trong history.
