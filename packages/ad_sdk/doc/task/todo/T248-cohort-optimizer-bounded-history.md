# T248 — Giới hạn lịch sử đã ký của CohortOptimizer

- **Loại:** Enhancement
- **Priority:** P2 · **Effort:** S
- **Confidence:** CONFIRMED unbounded retention; impact is gradual, not incident-proven
- **Status:** todo
- **Evidence:** `lib/src/monetization/cohort_optimizer.dart:59-79,81-100`; `test/cohort_optimizer_test.dart`
- **Dependency:** none

## Giá trị

Mỗi `recordSession()` tải toàn bộ record, thêm phiên mới, serialize và ký lại toàn bộ danh sách. Không thấy retention cap. Theo thời gian payload và chi phí xử lý tăng theo số phiên. Giới hạn cửa sổ lịch sử có thể giữ optimizer hữu dụng mà không tăng dữ liệu vô hạn.

## Phạm vi

- Đã chọn retention 90 ngày theo `timestampMs`; xác minh clock/future timestamp và giữ đủ mẫu hợp lệ cho từng provider. Đây là cửa sổ thời gian, không giới hạn cứng số record nếu ghi dày.
- Cắt record cũ trước khi ký/lưu; giữ nguyên xác minh chữ ký và fallback khi payload bị sửa/hỏng.
- Không thay thuật toán chọn provider, không thêm backend hay thu thập telemetry.

## Acceptance criteria

- [ ] Unit: vượt giới hạn retention thì chỉ giữ đúng record mới nhất; kiểm tra biên chính xác.
- [ ] Unit: sau trim payload vẫn verify được và recommendation dùng đúng cửa sổ giữ lại.
- [ ] Unit: dữ liệu cũ hợp lệ được đọc đúng; dữ liệu hỏng/tampered vẫn bị loại như hiện tại.
- [ ] Unit: ghi lỗi không làm mất bản signed state cũ.
- [ ] Widget test: N/A — optimizer không có UI; ghi lý do.
- [ ] Integration Android/iOS: persistence qua storage platform thật, nếu harness có thể kiểm chứng; không bịa test widget cho code không có UI.
- [ ] Smoke test thiết bị: ghi nhận kích thước payload trước/sau trên luồng nhiều session; không dùng dữ liệu người dùng thật.
- [ ] Audit độc lập diff, điểm >9/10; test và analyze liên quan pass.

## Prompt vòng lặp

Triển khai T248 theo TDD. Trước tiên đọc lại optimizer, test và task T90/T93/T97/T136/T146 để không thay đổi chính sách cohort đã chọn. Viết test retention, boundary, signature, recommendation và persistence failure trước khi sửa. End loop: audit changes + điểm /10; unit/widget/integration test mọi case (widget N/A phải có lý do), smoke trên thiết bị bằng dữ liệu tổng hợp; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.