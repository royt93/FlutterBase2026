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

## Kết quả

**Đã làm gì:**

Thêm 1 API mới cho SDK: `markCustomOverlayOnScreen(true/false)` và biến `customOverlayOnScreen`. Khi app tự vẽ 1 popup riêng (không đi qua `Navigator` bình thường của Flutter, mà "chèn" trực tiếp lên màn hình bằng `Overlay.insert`), app chỉ cần gọi hàm này để "báo" cho SDK biết: "tôi đang có popup riêng đang mở, đừng cho quảng cáo đè lên". SDK sẽ tự động chặn App Open (quảng cáo hiện khi mở lại app) và cả 3 loại quảng cáo toàn màn hình còn lại (interstitial, rewarded, rewarded-interstitial) trong lúc cờ này đang bật.

Đây làm y hệt cách SDK đã làm cho hộp thoại xin phép theo dõi quảng cáo (ATT) trước đây — chỉ khác là lần này áp dụng cho popup do CHÍNH app tự vẽ ra, một trường hợp mà SDK trước đây hoàn toàn không nhìn thấy được.

**2 lỗi thật phát hiện trong lúc review lại code (không phải lỗi giả định trước — code đã chạy được nhưng review kỹ mới lộ ra):**

1. Nếu app gọi API mới này TRƯỚC KHI SDK từng được khởi tạo lần nào (VD: app tự vẽ 1 lớp che màn hình ngay từ giây đầu tiên, trước khi gọi `AdManager().initialize()`), thì lúc SDK khởi tạo xong, cờ "đang bận" của SDK (`fullscreenBusy`, cái mà app có thể tự đọc để biết SDK có đang bận không) lại báo sai là "không bận" — dù thực tế popup vẫn đang mở. Đã sửa: SDK giờ đọc đúng giá trị cờ ngay khi vừa khởi tạo, không cần đợi có sự kiện gì khác xảy ra mới cập nhật.
2. Sâu hơn: cờ mới này bị đặt SAU 1 điều kiện "nếu SDK chưa có adapter quảng cáo thật thì coi như không bận" — nghĩa là nếu app gọi API mới TRƯỚC KHI `initialize()` chạy xong, SDK vẫn coi là "không bận" dù popup đang mở, y hệt lỗi số 1 nhưng ở một chỗ khác trong code. Đã sửa bằng cách đưa điều kiện kiểm tra cờ mới lên TRƯỚC điều kiện đó, giống cách hộp thoại ATT đã được xử lý đúng từ trước.
3. (lỗi nhỏ ở demo, không ảnh hưởng SDK thật) Trang demo trong `example/` nếu người dùng rời màn hình mà chưa đóng popup, chỉ tắt cờ chứ không tự dọn popup — để lại 1 popup "ma" còn hiển thị mà nút đóng của nó lại gây lỗi khi bấm. Đã sửa: rời màn hình sẽ tự dọn luôn popup.

Cả 3 lỗi này được `codex review` (công cụ audit độc lập) phát hiện ở vòng review đầu tiên, đã verify lại từng lỗi là có thật rồi mới sửa, không sửa mù.

**Test đã viết:**
- Unit test: 2 nhóm test mới trong `ad_manager_core_test.dart` (chặn 3 hàm "xem trước có chiếu được không" + chặn App Open lúc resume) + 1 file test riêng chuyên xác nhận lỗi số 1 ở trên (`t168_fullscreen_busy_seed_test.dart`).
- Widget test: 3 test cho trang demo mới (bật/tắt popup đúng cờ, cờ này thật sự chặn được quảng cáo thật của SDK, rời trang mà chưa đóng popup vẫn dọn sạch cờ).
- Integration test + smoke test thật trên **Pixel 7 Pro** (thiết bị thật, không phải giả lập): mở app thật, hiện popup tự vẽ, đưa app về nền rồi mở lại — log thật trên máy xác nhận dòng chữ `app-open on resume skipped — a custom host overlay is on screen`, tức là chính cơ chế mới này đã chặn App Open thật trên máy thật, không phải chỉ chặn trong môi trường test giả lập.

**Kết quả chạy toàn bộ test:**
- Toàn bộ SDK (`packages/ad_sdk`): 1872 test — 100% xanh (không có test nào bị hỏng do thay đổi này).
- Toàn bộ app mẫu (`example/`): 47 file test — 100% xanh.
- `flutter analyze`: sạch (chỉ còn 2 cảnh báo cũ, có từ trước, không liên quan việc này).
- `codex review`: vòng 1 tìm ra 3 lỗi thật (đã sửa hết), vòng 2 sạch — không còn lỗi.

**Tự chấm điểm: 9.5/10.** Trừ 0.5 vì đây là tính năng opt-in (SDK không tự động phát hiện được popup tự vẽ — app bắt buộc phải tự gọi API mới thì mới có tác dụng, một giới hạn kỹ thuật không thể tránh được của Flutter, đã ghi rõ trong README).
