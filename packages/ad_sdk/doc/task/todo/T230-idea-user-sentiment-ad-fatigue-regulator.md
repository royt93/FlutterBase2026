# T230 — Ý tưởng: Bộ điều tiết tần suất quảng cáo dựa trên phản ứng người dùng

- **Loại:** Idea
- **Priority:** P3 · **Severity:** LOW
- **Status:** 🔲 todo

## Vấn đề (Why)
Nếu người dùng bấm đóng quảng cáo ngay khi vừa hiện nút X (fast close < 1s), hoặc liên tục bấm quay lại, đây là tín hiệu ức chế quảng cáo (ad fatigue). Ép xem tiếp sẽ dẫn đến gỡ app hoặc đánh giá 1 sao.

## Đề xuất giải pháp & Acceptance Criteria
1. `AdFatigueRegulator` ghi nhận thời gian tương tác với ad fullscreen.
2. Nếu phát hiện liên tiếp 2 lần đóng vội, tự động giãn thời gian cooldown giữa 2 lần quảng cáo (vd từ 30s lên 60s).
3. Tự phục hồi về ngưỡng chuẩn sau một khoảng thời gian phiên bình thường.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Unit test: Tính toán độ mệt mỏi và điều chỉnh cooldown linh hoạt.
- Integration test: `example/integration_test/creative_fatigue_guard_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T230 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T230-idea-user-sentiment-ad-fatigue-regulator.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
