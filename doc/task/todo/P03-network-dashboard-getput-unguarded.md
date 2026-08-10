# P03 — `network_dashboard_screen.dart` gọi `Get.put` không guard trong `build()`

- **Priority:** P1 · **Severity:** MEDIUM · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/network_dashboard_screen.dart`

## Vấn đề
Dòng 17 gọi `Get.put(...)` không điều kiện trong `build()`, khác mọi sibling screen khác (`heatmap_screen.dart:35-37`, `benchmark_screen.dart:17-19`, `room_comparison_screen.dart:15-17`, `schedule_screen.dart:25-27`) đều guard bằng `Get.isRegistered<...>()` trước khi `Get.put`. Hệ quả: parent rebuild sẽ tạo lại controller, trigger lại `onInit()`→`refreshData()`, làm loading spinner public-IP/network-info nhấp lại không cần thiết.

## Bằng chứng
- `network_dashboard_screen.dart:17` — thiếu guard.
- Đối chiếu pattern đúng: `heatmap_screen.dart:35-37`, `benchmark_screen.dart:17-19`, `room_comparison_screen.dart:15-17`, `schedule_screen.dart:25-27`.

## Việc cần làm (đề xuất, chưa code)
- Thêm guard `if (!Get.isRegistered<NetworkDashboardController>()) Get.put(...)` giống các screen khác.

## Acceptance criteria
- [ ] `network_dashboard_screen.dart` dùng cùng pattern guard với các screen khác trong `presentation/`.
- [ ] Test: rebuild parent widget nhiều lần, verify `NetworkDashboardController.onInit()` chỉ chạy 1 lần.
