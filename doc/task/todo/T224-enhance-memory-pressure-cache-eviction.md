# T224 — Cải tiến thu hồi bộ nhớ chủ động khi OS phát tín hiệu Memory Pressure

- **Loại:** Enhancement
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** 🔲 todo

## Vấn đề (Why)
Hiện tại `AdManager().didHaveMemoryPressure()` chỉ ghi log an toàn mà chưa thực hiện giải phóng tài nguyên. Khi ứng dụng chạy trong môi trường RAM thấp (thiết bị Android 2GB/3GB hoặc iOS nền), việc giữ các slot preloaded hoặc cache nhật ký có thể khiến OS kill process (OOM).

## Đề xuất giải pháp & Acceptance Criteria
1. Khi `didHaveMemoryPressure()` được gọi, kích hoạt dọn dẹp nhẹ:
   - Flush và nén bộ đệm `AdEventLog` và `BypassAuditTrail`.
   - Giải phóng các slot fullscreen đã preloaded nhưng chưa dùng quá 15 phút.
   - Dọn các tombstone key cũ trong `InlineAdInstanceRegistry`.
2. Không làm gián đoạn các ad đang hiển thị hoặc widget ad đang mount.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Unit test: Giả lập `didHaveMemoryPressure()` và kiểm tra slot/cache được giải phóng.
- Widget test: Xác nhận widget banner/native không bị crash khi có memory pressure.
- Integration test: `example/integration_test/t212_memory_backpressure_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T224 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T224-enhance-memory-pressure-cache-eviction.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
