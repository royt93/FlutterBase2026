# P45 — Chuẩn hoá đăng ký controller qua GetX `Binding` thay vì `Get.put` rải rác trong `build()`

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập), gốc của cụm bug [[P03-network-dashboard-getput-unguarded]]

## Vấn đề / cơ hội
Nhiều `presentation/*_screen.dart` tự gọi `Get.put`/`Get.isRegistered` guard riêng trong `build()` — pattern lặp lại, dễ quên guard (đã xảy ra ở P03), khó test lifecycle controller nhất quán. Chuẩn `GetX` là dùng `Binding` gắn với route để quản lý lifecycle tập trung.

## Việc cần làm (đề xuất — cần thiết kế trước khi áp dụng toàn app, rủi ro regression cao nếu đổi hàng loạt)
- Chọn 1 screen làm pilot (đề xuất `NetworkDashboardScreen` vì đang có bug P03), viết `Binding` tương ứng, đổi route qua `GetPage(binding: ...)` hoặc `Get.to(binding: ...)`.
- Nếu ổn, áp dụng dần cho các screen còn lại — **không đổi hàng loạt cùng lúc**, rủi ro regression navigation cao.

## Acceptance criteria
- [ ] Pilot 1 screen chạy đúng qua `Binding`, không regression.
- [ ] Quyết định rõ có mở rộng ra toàn app hay chỉ áp dụng cho screen mới từ giờ.
