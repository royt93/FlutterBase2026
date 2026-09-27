# T228 — Tính năng mới: Custom Native Ad Builder với xác thực tuân thủ chính sách

- **Loại:** New Feature
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** 🔲 todo

## Vấn đề (Why)
Hiện tại Native Ad chủ yếu dựa trên template định sẵn (`TemplateType.medium/small` của Google hoặc view mặc định của AppLovin). Nhiều ứng dụng muốn tự vẽ UI Native Ad theo design system riêng nhưng sợ vi phạm chính sách hiển thị biểu tượng AdChoices.

## Đề xuất giải pháp & Acceptance Criteria
1. Cung cấp `CustomNativeAdBuilder` cho phép host tự định nghĩa layout Flutter.
2. Tự động đính kèm và kiểm tra bắt buộc biểu tượng AdChoices/AdOptionsView theo quy định Google/AppLovin.
3. Fail-safe: Nếu layout thiếu diện tích hiển thị nhãn quảng cáo, tự fallback về template chuẩn.

### Acceptance Criteria
- [ ] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [ ] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [ ] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [ ] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Widget test: Render custom layout và assert có AdChoices badge.
- Unit test: Bắt lỗi nếu custom view che khuất attribution.
- Integration test: `example/integration_test/native_ad_test.dart`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T228 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T228-feat-custom-native-ad-template-builder.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
