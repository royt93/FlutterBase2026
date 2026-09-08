# T168 — Quảng cáo mở lại app có thể đè lên popup tự vẽ riêng của app

**Loại:** bug/new-feature (mở rộng cơ chế chống chồng chéo giao diện)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state (đã tự đánh dấu "có thể trùng finding cũ, cần double-check")
**Quyết định chủ dự án (2026-09-08):** Sửa ngay (chọn phương án đầy đủ, không chỉ ghi tài liệu cảnh báo)

## Vấn đề (giải thích thực tế)
Quảng cáo toàn màn hình lúc mở lại app (App Open) có cơ chế tránh chồng lên hộp thoại đang mở — nhưng chỉ nhận diện được hộp thoại CHUẨN của Flutter (`PopupRoute` qua `Navigator`), không nhận diện được nếu dev app tự vẽ 1 lớp popup riêng theo cách khác (VD `Overlay.of(context).insert(...)` thủ công — ít gặp hơn nhưng có thật). Nếu xảy ra, quảng cáo có thể hiện đè lên popup đó của app, gây giao diện chồng chéo khó chịu.

Đây cùng lớp vấn đề đã fix cho ATT prompt (round 31, `markUmpFormOnScreen()`) nhưng chưa có tương đương cho overlay tuỳ ý của host.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_route_observer.dart:63` — `isDialogOnTop` chỉ thấy `PopupRoute` qua `Navigator`.
- Flutter không có API public để SDK tự động hook MỌI `OverlayEntry` tuỳ ý của host — cần 1 API mới để host TỰ KHAI BÁO "tôi đang có overlay riêng đang mở" (giống pattern `markUmpFormOnScreen()` đã có cho ATT).

## Việc cần làm
1. Thêm API công khai mới, VD `AdManager().markCustomOverlayOnScreen(bool value)` (hoặc tên tương tự nhất quán với `markUmpFormOnScreen`), để host tự báo khi họ có overlay tuỳ ý đang mở.
2. Sửa `isDialogOnTop` (hoặc điểm gọi `showAppOpenAdOnResume`) để kiểm tra thêm cờ mới này bên cạnh `PopupRoute`.
3. Viết test: host set cờ custom-overlay=true, xác nhận App Open không tự hiện khi resume.
4. Thêm demo trong `example/`: 1 popup tự vẽ bằng `Overlay.insert`, gọi đúng API mới khi mở/đóng, chứng minh App Open không đè lên.
5. Cập nhật CHANGELOG.md và README.md (mục 7 — App Open không chồng modal), giải thích rõ đây là API opt-in, host phải tự gọi.

## Prompt để chạy loop-fix
```
Thêm cơ chế mới vào packages/ad_sdk/lib/src/core/ad_route_observer.dart (và/hoặc ad_manager.dart nơi expose API công khai): isDialogOnTop hiện chỉ nhận diện PopupRoute qua Navigator (dòng ~63), không nhận diện overlay tự vẽ qua Overlay.of(context).insert() thủ công. Đọc cách markUmpFormOnScreen() đã làm cho ATT prompt (round 31) làm mẫu thiết kế: thêm API công khai tương tự (VD markCustomOverlayOnScreen(bool value)) để host tự khai báo khi có overlay riêng đang mở, lưu vào 1 cờ nội bộ, và sửa điểm quyết định showAppOpenAdOnResume để kiểm tra thêm cờ này bên cạnh isDialogOnTop hiện có. Viết unit test: set cờ true, xác nhận App Open bị chặn khi resume; set false, xác nhận hoạt động bình thường. Thêm demo trong example/ với 1 popup tự vẽ bằng Overlay.insert gọi đúng API mới.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho API mới + tích hợp vào quyết định `showAppOpenAdOnResume`; widget/integration test qua demo overlay tự vẽ.
3. Demo trong `example/` + CHANGELOG.md/README.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, mở popup tự vẽ trong demo, đưa app về nền rồi mở lại, xác nhận App Open không đè lên popup.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
