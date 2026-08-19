# P34 — Tự động mở Settings khi permission location bị deny vĩnh viễn, không hỏi trước

- **Priority:** P1 · **Severity:** HIGH · **Status:** ✅ done (2026-08-11)
- **Nguồn:** subagent đọc source (đã verify trực tiếp)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/network_info_service.dart:273-278`

## Vấn đề
`_requestLocationPermission()` (dòng 248-286): khi `status.isPermanentlyDenied`, code gọi `await openAppSettings()` (dòng 277) **ngay lập tức, không hỏi xác nhận** — kéo user ra khỏi app vào màn OS Settings. Hàm này được gọi từ `getCurrentNetworkInfo()` (dòng 292), mà `getCurrentNetworkInfo()` lại được gọi ở nhiều nơi lặp lại: mỗi lần lưu test (`stressor_controller.dart:585`) và mỗi lần refresh dashboard (`network_dashboard_service`/`network_info_service.dart:220`). Kết quả: user đã từ chối permission 1 lần, mỗi lần chạy test hoặc mở dashboard đều bị đẩy ra Settings mà không có cách tắt/bỏ qua.

## Bằng chứng
- `network_info_service.dart:273-278` — `openAppSettings()` không điều kiện, không dialog xác nhận trước.
- `network_info_service.dart:292` — gọi `_requestLocationPermission()`.
- `stressor_controller.dart:585` — gọi lại sau mỗi test.

## Việc cần làm (đề xuất, chưa code)
- Thêm dialog xác nhận trước khi gọi `openAppSettings()` (VD: "Cần quyền vị trí để đọc SSID, mở Settings?" — Có/Không).
- Thêm cờ nhớ "user đã bỏ qua" (SharedPreferences) để không hỏi lại liên tục mỗi lần refresh — chỉ hỏi lại khi user chủ động bấm nút liên quan tới SSID/vị trí.
- Xem [[P53-permission-denied-explainer-dialog]] (idea liên quan, UX chi tiết hơn).

## Acceptance criteria
- [x] Từ chối permission vĩnh viễn 1 lần → không còn bị tự động đẩy ra Settings ở lần refresh/test tiếp theo mà không có xác nhận.
- [x] Có đường quay lại (nút riêng) để user tự mở Settings khi họ muốn.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm chung 1 PR với [[P53-permission-denied-explainer-dialog]]: bỏ auto-open Settings (ticket này) + thêm dialog giải thích trước lần request đầu (P53) — cùng file `network_info_service.dart`, cùng luồng permission nên sửa 1 lần cho trọn UX.

## Kết quả (2026-08-11)
`_requestLocationPermission()`: nhánh `isPermanentlyDenied` không còn tự gọi `openAppSettings()` — thay bằng `_maybeShowSettingsPromptDialog()` (`Get.dialog<bool>`, nút "Bỏ qua"/"Mở Settings"), chọn "Bỏ qua" ghi flag `keyLocationSettingsPromptDismissed` qua `SharedPreferencesUtil` để không hỏi lại các lần sau. Thêm nút `Icons.settings` riêng trong `NetworkDashboardScreen` app bar gọi `openAppSettings()` trực tiếp — đường quay lại chủ động cho user. Test: `test/network_info_service_permission_test.dart` (mock method channel `flutter.baseflow.com/permissions/methods`).
