# T229 — Ý tưởng: Cơ chế hiển thị House Ad nội bộ khi No-Fill hoặc Offline

- **Loại:** Idea
- **Priority:** P3 · **Severity:** LOW
- **Status:** 🔲 todo

## Vấn đề (Why)
Khi thiết bị mất mạng hoặc mạng quảng cáo báo No-Fill (hết kho), vị trí banner thường để trống hoặc ẩn đi. Thay vào đó, app có thể hiển thị banner quảng bá tính năng nội bộ (House Ad) hoặc khuyến mãi VIP.

## Đề xuất giải pháp & Acceptance Criteria
1. Cho phép host cấu hình danh sách `HouseAdItem` (ảnh asset cục bộ, tiêu đề, deep link).
2. Khi `BannerAdWidget` no-fill hoặc offline kéo dài >10s, hiển thị House Ad nội bộ thay vì khoảng trắng.
3. Click vào House Ad điều hướng nội bộ (vd: mở màn hình VIP Redeem Screen).

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Widget test: Giả lập No-fill và kiểm tra House Ad hiển thị đúng.
- Unit test: Xác nhận không ghi nhận doanh thu giả hoặc nhầm lẫn event.
- Integration test: `example/integration_test/slot_state_panel_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T229 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T229-idea-offline-house-ad-fallback.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
