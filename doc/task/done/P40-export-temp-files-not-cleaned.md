# P40 — File export tạm (CSV/PDF/JSON) không bị xoá sau khi share, tích lũy theo thời gian

- **Priority:** P3 · **Severity:** LOW · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập, đã verify lại trực tiếp)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/history_controller.dart:378-392,579-605`

## Vấn đề
2 luồng export (`exportHistory`-kiểu và `exportIspDisputeReport`) đều: lấy `getTemporaryDirectory()`, viết file (`writeAsString`/`writeAsBytes`), rồi `Share.shareXFiles([XFile(filePath, ...)])`. Không có bước `File(filePath).delete()` nào sau khi share xong (hoặc khi share bị cancel) ở cả 2 luồng — file tạm cộng dồn trong temp dir mỗi lần user export, không được dọn.

## Bằng chứng
- `history_controller.dart:378-392` — luồng export CSV/JSON/PDF, không có `.delete()`.
- `history_controller.dart:579-605` — luồng export ISP dispute PDF, không có `.delete()`.

## Việc cần làm (đề xuất, chưa code)
- Sau khi `Share.shareXFiles(...)` hoàn tất (hoặc trong `finally`), gọi `file.delete()` nếu file vẫn tồn tại.
- Cân nhắc: `Share.shareXFiles` trả `ShareResult` — kiểm tra không cần giữ file lại cho retry trước khi xoá ngay.

## Acceptance criteria
- [ ] Export nhiều lần liên tục → temp dir không tích luỹ file export cũ (kiểm tra bằng cách list dir trước/sau).
