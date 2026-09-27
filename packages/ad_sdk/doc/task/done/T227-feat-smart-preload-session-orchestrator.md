# T227 — Tính năng mới: Bộ điều phối nạp trước thông minh theo trạng thái phiên và pin

- **Loại:** New Feature
- **Priority:** P2 · **Severity:** LOW
- **Status:** 🔲 todo

## Vấn đề (Why)
Nạp trước (Preload) quảng cáo giúp sẵn sàng hiển thị ngay lập tức, nhưng nếu thiết bị đang yếu pin (Battery Saver) hoặc mạng yếu, việc nạp ồ ạt gây tốn năng lượng và lãng phí request.

## Đề xuất giải pháp & Acceptance Criteria
1. Xây dựng `AdPreloadOrchestrator` phối hợp với `AdSafetyConfig`:
   - Trì hoãn preload khi pin <15% hoặc đang ở chế độ tiết kiệm dữ liệu.
   - Lên lịch preload thông minh theo xác suất người dùng sắp chạm điểm chuyển cảnh.
2. Cung cấp API bật/tắt linh hoạt cho host app.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Unit test: Kiểm tra quyết định preload theo tình trạng pin và kết nối.
- Widget test: Thử nghiệm trong flow demo splash -> main.
- Integration test: `example/integration_test/app_boot_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T227 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T227-feat-smart-preload-session-orchestrator.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
