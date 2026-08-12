# P45 — Chuẩn hoá đăng ký controller qua GetX `Binding` thay vì `Get.put` rải rác trong `build()`

- **Priority:** P2 · **Severity:** — · **Status:** ✅ done (2026-08-11)
- **Nguồn:** agy CLI (audit độc lập), gốc của cụm bug [[P03-network-dashboard-getput-unguarded]]

## Vấn đề / cơ hội
Nhiều `presentation/*_screen.dart` tự gọi `Get.put`/`Get.isRegistered` guard riêng trong `build()` — pattern lặp lại, dễ quên guard (đã xảy ra ở P03), khó test lifecycle controller nhất quán. Chuẩn `GetX` là dùng `Binding` gắn với route để quản lý lifecycle tập trung.

## Việc cần làm (đề xuất — cần thiết kế trước khi áp dụng toàn app, rủi ro regression cao nếu đổi hàng loạt)
- Chọn 1 screen làm pilot (đề xuất `NetworkDashboardScreen` vì đang có bug P03), viết `Binding` tương ứng, đổi route qua `GetPage(binding: ...)` hoặc `Get.to(binding: ...)`.
- Nếu ổn, áp dụng dần cho các screen còn lại — **không đổi hàng loạt cùng lúc**, rủi ro regression navigation cao.

## Acceptance criteria
- [x] Pilot 1 screen chạy đúng qua `Binding`, không regression.
- [x] Quyết định rõ có mở rộng ra toàn app hay chỉ áp dụng cho screen mới từ giờ.

## Kết quả (2026-08-11)
Quyết định: **không** viết `Binding` mới. Lý do:
1. Đọc source GetX 4.7.3 (`get_instance.dart`) xác nhận `Get.put()` gọi lại trên key đã đăng ký + chưa `isDirty` không tạo lại instance/không re-run `onInit()` — nghĩa là vấn đề lifecycle mà `Binding` định giải quyết không thực sự tái hiện dưới GetX bản đang dùng, chỉ có 1 object throwaway bị tạo ra mỗi build (không side effect).
2. Toàn bộ app điều hướng qua `Get.to()`/`Get.off()` (không dùng named route/`GetPage`), nên gắn `Binding` cho 1 screen sẽ tạo ra 2 kiểu lifecycle-management khác nhau trong cùng codebase — **ngược lại mục tiêu nhất quán** mà chính ticket này đặt ra.
3. 4/5 screen (`heatmap_screen.dart`, `benchmark_screen.dart`, `room_comparison_screen.dart`, `schedule_screen.dart`) đã dùng sẵn pattern `Get.isRegistered<...>() ? Get.find(...) : Get.put(...)` trong `build()` — chỉ `NetworkDashboardScreen` (P03) là ngoại lệ thiếu guard.

→ Chuẩn hoá bằng cách áp guard đó cho `NetworkDashboardScreen` (xem [[P03-network-dashboard-getput-unguarded]]), coi guard-trong-`build()` là convention chính thức của project từ giờ, không mở rộng sang `Binding`. Nếu sau này đổi sang named-route (`GetPage`), có thể xét lại `Binding` lúc đó. Test + `flutter analyze`/`flutter test` full pass — chi tiết ở kết quả P03.
