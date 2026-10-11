# T249 — Ràng buộc dữ liệu đầu vào cohort metrics

- **Loại:** Fix candidate / boundary validation
- **Priority:** P3 · **Effort:** S
- **Confidence:** HYPOTHESIS — API public nhận số âm; cần xác định caller contract và semantics trước khi gọi là bug
- **Status:** todo
- **Evidence:** `lib/src/monetization/cohort_optimizer.dart:59-79,128-139`; `test/cohort_optimizer_test.dart`
- **Dependency:** T248 chỉ nếu chọn chung semantics retention

## Giá trị

`recordSession()` nhận `impressions` và `revenueMicros` từ caller công khai, rồi đưa trực tiếp vào phép tính eCPM. Số âm có thể làm lệch gợi ý provider, nhưng chưa xác minh có caller hợp lệ nào truyền dữ liệu sai hay contract hiện tại cho phép số âm. Xác định contract trước; không thêm validation cho input không thể xảy ra theo contract.

## Phạm vi

- Tra cứu toàn bộ call sites, docs và model semantics.
- Đã chọn: chỉ xác minh contract và caller; không đổi code nếu chưa thấy contract bị vi phạm hoặc dữ liệu đầu vào không tin cậy.
- Giữ `0` impressions/revenue hợp lệ nếu product semantics hiện tại yêu cầu.
- Không đổi thuật toán optimizer hay đổi data từ provider.

## Acceptance criteria

- [ ] Có kết luận bằng chứng về miền hợp lệ của impressions/revenue và caller hiện tại.
- [ ] Nếu contract cấm số âm: unit test âm cho từng field, zero, giá trị biên dương và chứng minh storage/recommendation không bị mutate khi reject.
- [ ] Nếu contract đã đảm bảo non-negative: đóng task là không cần đổi code, cập nhật test/documentation chỉ khi có gap cụ thể.
- [ ] Widget test: N/A — không có UI.
- [ ] Integration Android/iOS: chỉ cần nếu API được gọi trực tiếp qua bridge/native; nếu không, ghi rõ không áp dụng.
- [ ] Smoke test thiết bị chỉ cho behavior thực sự thay đổi; không chạy ad thật để thử số liệu tổng hợp.
- [ ] Audit độc lập diff/contract, điểm >9/10 nếu có code change.

## Prompt vòng lặp

Điều tra T249 trước khi sửa. Đọc mọi call site, API docs và test; không mặc định số âm là lỗi nếu contract chưa xác nhận. Nếu boundary cần validate, viết test đỏ trước, bảo đảm không ghi đè state hợp lệ khi input bị reject. End loop: audit lại changes, chấm /10; bổ sung unit/widget/integration theo tính áp dụng, smoke thiết bị nếu có runtime behavior; chỉ khi test/analyze pass và điểm >9/10 mới commit/push theo yêu cầu task. Nếu không cần code, ghi rõ chứng cứ và kết luận REFUTED.