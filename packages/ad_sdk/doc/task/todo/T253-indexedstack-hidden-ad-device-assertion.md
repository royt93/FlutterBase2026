# T253 — Chứng minh device test không load ad ở tab ẩn

- **Loại:** Test enhancement
- **Priority:** P3 · **Effort:** M
- **Confidence:** HYPOTHESIS test gap; unit tests hiện là chứng cứ chính
- **Status:** todo
- **Evidence:** `example/integration_test/banner_indexedstack_visibility_test.dart`, `example/integration_test/native_indexedstack_visibility_test.dart` hiện chuyển tab và chủ yếu xác nhận không có exception; đối chiếu unit/widget visibility tests.
- **Dependency:** none

## Giá trị

Device tests hiện chưa chứng minh trực tiếp contract “tab ẩn không load/show”. Bổ sung assertion chỉ khi integration harness quan sát được load/show mà không dùng impression giả hoặc ad thật khó điều khiển. Unit tests vẫn là proof chính nếu device signal không ổn định.

## Phạm vi

- Đã chọn: điều tra trước; chỉ thêm assertion nếu test harness có signal ổn định, nếu không kết luận REFUTED.
- Kiểm tra test harness hiện tại có thể đọc fake bridge request/callback hoặc event stream trên simulator/device không.
- Thêm assertion ẩn/hiện cho banner và native ở IndexedStack nếu tín hiệu đáng tin cậy.
- Không tuyên bố kiểm thử impression thật; không thử auto-dismiss AppLovin creative.

## Acceptance criteria

- [ ] Chứng minh trước rằng test có thể phân biệt tab active/inactive bằng signal ổn định.
- [ ] Device test xác nhận hidden child không bắt đầu load/show trong thời gian quan sát; active child vẫn có thể load theo điều kiện harness.
- [ ] Unit/widget tests tiếp tục kiểm tra visibility gate chính, bao gồm mounted inactive child và active toggle.
- [ ] Android + iOS integration test pass nếu harness support cả platform; nếu không, ghi limitation và REFUTED thay vì assertion flaky.
- [ ] Smoke test device dùng bridge/test ads, ghi rõ signal được kiểm tra.
- [ ] Audit độc lập >9/10.

## Prompt vòng lặp

Điều tra T253: đọc integration/unit tests và fixture bridge trước. Không thêm wait-and-hope assertion. Prove signal có ý nghĩa và deterministic trước; nếu không thể observably test trên device thì đóng REFUTED, không sửa production visibility code. End loop: audit diff + điểm /10, unit/widget/integration mọi case hợp lý và smoke thiết bị Android/iOS; chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.