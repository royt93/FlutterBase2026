# T226 — Cải tiến Adaptive Banner thích ứng màn hình gập (Foldable) và xoay ngang

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** LOW
- **Status:** 🔲 todo

## Vấn đề (Why)
Trên thiết bị Android màn hình gập (Samsung Galaxy Z Fold) hoặc iPad chia đôi màn hình (Split View), chiều rộng cửa sổ thay đổi liên tục khi mở/gập máy. Banner AdWidget hiện tại có thể bị méo tỉ lệ hoặc giữ kích thước cũ.

## Đề xuất giải pháp & Acceptance Criteria
1. Lắng nghe thay đổi `MediaQueryData.size` và `DisplayFeatures` (hinge/fold sensor).
2. Debounce tự động tính toán lại kích thước Anchored Adaptive Banner khi màn hình gập/mở.
3. Tự động reload ad đúng kích thước mới mà không gây nhấp nháy UI.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Widget test: Thay đổi kích thước màn hình qua `tester.binding.setSurfaceSize`.
- Unit test: Xác nhận tính toán lại adaptive size đúng chuẩn AdMob/AppLovin.
- Integration test: `example/integration_test/banner_ad_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T226 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T226-enhance-foldable-tablet-adaptive-banner-resize.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
