# P24 — Gắn/sửa `roomTag` cho test cũ trong history

- **Priority:** P2 · **Severity:** — · **Status:** ✅ done (2026-08-11)
- **Nguồn:** subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/room_comparison_screen.dart:32`, `history_screen.dart`, `widgets/room_tag_bottom_sheet.dart`

## Vấn đề / cơ hội
`room_comparison_screen.dart:32` hiện tự động bỏ qua (silently drop) mọi kết quả chưa gắn `roomTag`. Người dùng chỉ gắn được room tag lúc tạo test mới, không sửa/gắn lại được cho test cũ đã lưu trong history — làm giảm giá trị của mọi test đã chạy trước khi feature room-tag ra đời (và tiền đề cần cho P17, P30).

## Việc cần làm (đề xuất, chưa code)
- Thêm action "Gắn/Sửa phòng" trong `history_screen.dart` hoặc `test_detail_screen.dart` — mở lại `room_tag_bottom_sheet.dart` (đã tồn tại), lưu update vào `TestResult` đã lưu (dùng `copyWith`, chú ý bug về `copyWith` không clear-được-null đã ghi trong report subagent nếu liên quan).

## Bổ sung (2026-08-11, audit vòng 2 — claude CLI)
Severity nên nâng: `room_comparison_screen.dart` không chỉ bỏ qua test chưa gắn `roomTag`, mà filter còn loại luôn mọi test có `isSuccessful == false` (kể cả đã gắn tag) — làm mất tín hiệu "phòng này test hay fail/timeout", vốn cũng là 1 dạng bằng chứng vùng sóng yếu. Khi làm ticket này, cân nhắc quyết định rõ: hiển thị riêng test failed trong room đó (không gộp vào avg speed) thay vì filter bỏ hoàn toàn.

## Acceptance criteria
- [x] Có thể gắn/sửa room tag cho bất kỳ test đã lưu trong history.
- [x] Test cũ được gắn tag mới xuất hiện đúng trong `room_comparison_screen.dart` (không còn bị filter bỏ).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm [[P42-copywith-cannot-null-fields]] trước — ticket này cần `copyWith` nhận được `null` có chủ đích cho `roomTag` (VD user gỡ tag đã gắn sai) thì mới code đúng, không dùng workaround riêng.

## Kết quả (2026-08-11)
- `test_detail_screen.dart`: thêm icon "Edit room tag" trên AppBar + dòng `room_tag` info-row giờ luôn hiện (kể cả chưa tag, hiện "Not tagged") và tap được để mở lại `room_tag_bottom_sheet.dart`. Hiển thị dùng `Rx<String?> _roomTag` riêng bọc `Obx` nên cập nhật ngay không cần reload/back.
- `room_tag_bottom_sheet.dart`: `onTag` đổi sang nhận `String?`; prefill `TextField` với tag hiện có (sửa thay vì chỉ gắn mới); thêm nút "Remove tag" (thay chỗ nút Skip) khi test đã có tag, gọi `onTag(result, null)` — dùng đúng sentinel null-clear của P42. Sửa luôn 1 bug tiềm ẩn phát hiện qua test: `customController.dispose()` gọi đồng bộ trong `whenComplete` có thể trúng "TextEditingController used after disposed" vì `TextField` còn 1 frame rebuild trong lúc sheet đang đóng — dời dispose vào `addPostFrameCallback`.
- `history_controller.dart`: thêm `retagResult(TestResult, String?)` — không phụ thuộc `StressorController` (không chắc đã `Get.put()` khi vào History trực tiếp), dùng lại `applyRoomTagUpdate()` có sẵn để sync reactive list ngay, rồi mới `await _storage.saveTestResult()` (try/catch, lỗi chỉ log không throw — cùng convention với `StressorController.updateRoomTag`).
- `stressor_controller.dart`: `updateRoomTag` đổi tham số `roomTag` sang `String?` để khớp `onTag` signature mới (không đổi logic).
- `room_comparison_screen.dart`: filter đổi từ `roomTag != null && isSuccessful` sang chỉ `roomTag != null` — test đã tag nhưng failed vẫn hiện trong nhóm phòng, chỉ bị loại khỏi tính avg/peak/min (dùng subset `successful`), kèm dòng note cam "N test thất bại ở phòng này" khi có.
- Translations: thêm `room_tag_remove`, `room_tag_edit`, `room_tag_none`, `room_comparison_failed_note` (en_us.dart + vi_vn.dart).
- Test: `test/test_detail_retag_test.dart` (mới, 2 test: set tag từ trạng thái chưa tag, remove tag từ trạng thái đã tag) + cập nhật `test/wave6_room_tag_test.dart`'s grouping-math tests để khớp filter mới (tagged-but-failed ở lại nhóm, chỉ loại khỏi phép tính). `flutter analyze` sạch, `flutter test` 137/137 pass.
