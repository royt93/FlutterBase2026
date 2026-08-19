# P07 — `TestDetailScreen` crash risk khi mở trực tiếp (không qua History)

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** ✅ done (2026-08-12)
- **Nguồn:** codex CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/test_detail_screen.dart`

## Vấn đề
Dòng 598 gọi `Get.find<HistoryController>()` lúc xoá kết quả, giả định controller đã được register (đúng khi mở từ `HistoryScreen`). Nếu `TestDetailScreen` được mở trực tiếp bằng route khác (deep link, notification tap...) mà `HistoryController` chưa `Get.put`, hành động xoá sẽ crash với `"HistoryController" not found`.

## Bằng chứng
- `test_detail_screen.dart:598`.

## Việc cần làm (đề xuất, chưa code)
- Guard bằng `Get.isRegistered<HistoryController>()` trước khi `Get.find`, hoặc đảm bảo route tới `TestDetailScreen` luôn đi qua nơi đã `Get.put(HistoryController())` trước (audit lại toàn bộ nơi push `TestDetailScreen`, bao gồm route mới ở P16 heatmap drill-down).

## Acceptance criteria
- [x] Mở `TestDetailScreen` trực tiếp (không qua `HistoryScreen`) rồi bấm xoá — không crash.
- [x] Widget test dựng `TestDetailScreen` standalone (không pre-register `HistoryController`), verify hành vi xoá không throw.

## Kết quả (2026-08-12)
Theo quyết định ở [[P45-standardize-getx-binding]] (giữ pattern guard trong `build()`, không dùng `Binding`): thêm helper `_historyController()` trong `TestDetailScreen`
(`Get.isRegistered<HistoryController>() ? Get.find(...) : Get.put(...)`), thay cho `Get.find<HistoryController>()` thô ở **cả 2** call site — delete-flow gốc (dòng ~634) và `_editRoomTag()` (dòng 38, thêm ở P24 sau khi ticket này được viết — cùng lỗi, cùng fix).
`HistoryController.onInit()` chỉ gọi `_initializeStorage()` + `loadHistory()` qua singleton `TestHistoryStorage.instance`, không phụ thuộc state của screen gọi trước đó → tự `Get.put()` on-demand an toàn.
Test mới `test/p07_test_detail_standalone_test.dart`: dựng `TestDetailScreen` standalone (không pre-register `HistoryController`), bấm xoá và sửa room tag — cả 2 không throw, controller tự đăng ký. Test xoá còn lộ ra path `deleteResult()` gọi `UIUtils.showToast` cần `ToastificationWrapper` bao ngoài (giống `main.dart`) — đã thêm vào test app wrapper, không phải bug trong code app.
`flutter analyze` sạch, `flutter test` 161/161 pass.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Làm [[P45-standardize-getx-binding]] trước (pilot `NetworkDashboardScreen`), rồi mới quay lại kiểm tra ticket này còn tồn không — nếu Binding chuẩn hoá đúng, guard đăng ký controller có thể tự áp dụng cho `TestDetailScreen` mà không cần vá riêng.
