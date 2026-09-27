# T222 — Fix tool/api_surface.dart bỏ sót ExtensionElement2 trong golden API guard

- **Loại:** Fix (Bug / Tech Debt)
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** ✅ done

## Vấn đề (Why)
`tool/api_surface.dart` chỉ duyệt `InterfaceElement2` (classes, enums, mixins, extension types) mà bỏ qua `ExtensionElement2` (extension thuần `extension Foo on Bar`). Nếu thêm hoặc đổi extension method trong public barrel `lib/applovin_admob_sdk.dart`, `api_golden_test.dart` không phát hiện được breaking change.

## Đề xuất giải pháp & Acceptance Criteria
1. Mở rộng `tool/api_surface.dart` để duyệt `ExtensionElement2`.
2. Liệt kê các method, getter, setter khai báo trong extension vào chữ ký API surface.
3. Cập nhật `test/api_golden_test.dart` và tái sinh `test/goldens/public_api_surface.txt`.
4. Thêm test case kiểm thử phát hiện thay đổi trong extension.

### Acceptance Criteria
- [x] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [x] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [x] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Unit test: `test/api_golden_test.dart` kiểm tra extension surface.
- Golden test: Xác nhận public API golden khớp 100%.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T222 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T222-fix-api-surface-extension-element-omission.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.
