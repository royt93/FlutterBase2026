# P03 — `network_dashboard_screen.dart` gọi `Get.put` không guard trong `build()`

- **Priority:** P1 · **Severity:** MEDIUM · **Status:** ✅ done (2026-08-11)
- **Nguồn:** subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/network_dashboard_screen.dart`

## Vấn đề
Dòng 17 gọi `Get.put(...)` không điều kiện trong `build()`, khác mọi sibling screen khác (`heatmap_screen.dart:35-37`, `benchmark_screen.dart:17-19`, `room_comparison_screen.dart:15-17`, `schedule_screen.dart:25-27`) đều guard bằng `Get.isRegistered<...>()` trước khi `Get.put`. Hệ quả: parent rebuild sẽ tạo lại controller, trigger lại `onInit()`→`refreshData()`, làm loading spinner public-IP/network-info nhấp lại không cần thiết.

## Bằng chứng
- `network_dashboard_screen.dart:17` — thiếu guard.
- Đối chiếu pattern đúng: `heatmap_screen.dart:35-37`, `benchmark_screen.dart:17-19`, `room_comparison_screen.dart:15-17`, `schedule_screen.dart:25-27`.

## Bổ sung (2026-08-11, audit vòng 2 — claude CLI)
Cùng gốc: `Get.put` rải rác trong `build()` ở nhiều screen khác nhau (không chỉ file này) khiến lifecycle controller không nhất quán — nên cân nhắc chuẩn hoá bằng GetX `Binding` (xem [[P45-standardize-getx-binding]] nếu tách task riêng) thay vì chỉ vá từng chỗ.

## Việc cần làm (đề xuất, chưa code)
- Thêm guard `if (!Get.isRegistered<NetworkDashboardController>()) Get.put(...)` giống các screen khác.

## Acceptance criteria
- [x] `network_dashboard_screen.dart` dùng cùng pattern guard với các screen khác trong `presentation/`.
- [x] Test: rebuild parent widget nhiều lần, verify `NetworkDashboardController.onInit()` chỉ chạy 1 lần.

## Kết quả (2026-08-11)
Thêm guard `Get.isRegistered<NetworkDashboardController>() ? Get.find(...) : Get.put(...)` trong `build()`, giống 4 sibling screen. Trước khi fix đã đọc thẳng source GetX 4.7.3 (`get_instance.dart`, `_insert<S>()`) để xác nhận: gọi lại `Get.put()` trên key đã đăng ký và chưa `isDirty` (chỉ dirty khi bị `delete()`) thì KHÔNG tạo lại instance, `onInit()` không chạy lại — nghĩa là mô tả "rebuild trigger lại onInit → nhấp loading" trong ticket không tái hiện đúng như tả dưới GetX 4.7.3, thiệt hại thực tế chỉ là 1 object throwaway bị tạo ra mỗi lần `build()` (constructor `NetworkDashboardController` không có side effect). Vẫn áp dụng guard vì rẻ, không rủi ro, và đúng mục tiêu nhất quán của [[P45-standardize-getx-binding]]. Test: `test/p45_getx_guard_test.dart` — verify guard pattern giữ nguyên instance + onInit chạy 1 lần qua GetX thật (không mock), và assert source file chứa guard. `flutter analyze` sạch, `flutter test` 159/159 pass. Xem quyết định đầy đủ (không dùng `Binding`) ở [[P45-standardize-getx-binding]].
