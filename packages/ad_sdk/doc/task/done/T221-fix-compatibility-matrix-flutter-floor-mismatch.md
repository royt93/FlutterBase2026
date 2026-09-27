# T221 — Fix lệch phiên bản Flutter trong CompatibilityMatrix vs pubspec.yaml/CI/README

- **Loại:** Fix (Bug)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** ✅ done

## Vấn đề (Why)
`CompatibilityMatrix.minimum` đang khai báo cứng `flutter: '3.35.1'`, trong khi `pubspec.yaml` nâng lên `flutter: '>=3.38.1'`, `.github/workflows/test.yml` dùng `flutter-version: '3.38.1'`, và README vẫn ghi `3.27.0`. `CompatibilityMatrix.isSupported` thực hiện so sánh chính xác (`target.flutter == min.flutter`). Khi chạy validator trên Flutter 3.38.1 thật, gate sẽ vỡ hoặc báo sai.

## Đề xuất giải pháp & Acceptance Criteria
1. Đồng bộ `CompatibilityMatrix.minimum` lên `3.38.1` để khớp với `pubspec.yaml` và CI.
2. Cập nhật README.md badge và requirement từ 3.27.0 lên 3.38.1.
3. Cập nhật unit test `test/compatibility_matrix_test.dart` và example integration test `t215_compatibility_matrix_test.dart`.
4. Đảm bảo `tool/validate_compatibility_matrix.dart` chạy pass sạch.

### Acceptance Criteria
- [x] Code thay đổi tối giản, đúng kiến trúc, không tạo abstraction thừa thãi.
- [x] Không ảnh hưởng đến các quyết định sản phẩm đã duyệt của owner.
- [x] Đầy đủ bộ kiểm thử Unit + Widget + Integration theo đúng case.
- [x] `flutter analyze` sạch 0 cảnh báo, `flutter test` toàn bộ pass xanh.

## Kế hoạch kiểm thử
- Unit test: `test/compatibility_matrix_test.dart` assert 3.38.1 là floor, 3.37.x bị reject.
- Integration test: `example/integration_test/t215_compatibility_matrix_test.dart`.
- Tool run: `dart run tool/validate_compatibility_matrix.dart android admob`.

## Prompt vòng lặp (Loop Prompt)
Triển khai task T221 theo quy trình TDD chuẩn:
1. Đọc kỹ file mô tả `doc/task/todo/T221-fix-compatibility-matrix-flutter-floor-mismatch.md` và acceptance criteria.
2. Viết kiểm thử trước (Red-Green-Refactor) bao phủ mọi trường hợp: success, failure, offline, invalid input, và lifecycle.
3. Thực hiện sửa đổi code tối giản, tuân thủ nguyên tắc defensive programming của SDK.
4. Tín hiệu kết thúc vòng lặp (End Loop):
   - Hãy audit lại toàn bộ code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case.
   - Chạy smoke test lên device chứng minh hoạt động thực tế.
   - Nếu work và điểm >9/10 thì commit và push code.

> T221 note: no widget test added — CompatibilityMatrix is pure Dart with no widget surface; inventing a demo UI for coverage would violate minimal-diff. Unit (19 cases incl. 9 new boundary cases) + t215 integration + validator-tool runs cover it.
