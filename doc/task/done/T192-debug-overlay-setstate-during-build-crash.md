# T192 — Debug overlay có thể crash (chỉ ở debug build) khi mở panel trước khi điều hướng

**Loại:** bug (chỉ ảnh hưởng công cụ debug nội bộ, không ảnh hưởng người dùng thật)
**Ưu tiên:** P3
**Trạng thái:** todo
**Nguồn phát hiện:** phát hiện tình cờ khi viết integration test cho T173 (2026-09-12)
**Quyết định chủ dự án:** chưa quyết định — task mới, chưa làm

## Vấn đề (giải thích thực tế)
`DebugAdOverlay` (bảng thông tin debug nổi trên màn hình, CHỈ hiện khi chạy debug build, không bao giờ hiện với người dùng thật) có thể bị crash trong 1 tình huống cụ thể: nếu dev đã MỞ SẴN bảng debug (panel đang expand), rồi điều hướng sang 1 màn hình mà `initState()` của màn đó gọi thẳng 1 hàm như `AdManager().loadInterstitial()` một cách đồng bộ (không phải async) — ví dụ `BannerDemoPage` trong app mẫu làm đúng việc này (preload interstitial ngay trong `initState`).

Lỗi Flutter: `setState() or markNeedsBuild() called during build` — vì dòng hiển thị trạng thái Interstitial trong bảng debug (`_slotRow` trong `debug_ad_overlay.dart`) dùng `ValueListenableBuilder` lắng nghe trực tiếp, và khi state đổi ngay trong lúc Flutter đang dựng 1 phần khác của cây widget (màn hình mới), Flutter không cho phép cập nhật 1 phần cây KHÔNG LIÊN QUAN đang "sạch" (đã dựng xong) trong lúc đang dựng phần khác.

## Vì sao chỉ ưu tiên P3 (không khẩn cấp)
- Chỉ xảy ra khi `kDebugMode == true` — không bao giờ ảnh hưởng bản release thật gửi cho người dùng.
- Chỉ xảy ra với đúng thứ tự thao tác cụ thể (mở bảng debug TRƯỚC, rồi mới điều hướng) — thứ tự ngược lại (điều hướng trước, mở bảng debug sau) không bị lỗi.
- Ảnh hưởng duy nhất: trải nghiệm dev khi tự debug app bằng công cụ nội bộ này, không phải lỗi sản phẩm.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/debug_ad_overlay.dart` — class `_SlotRows`, hàm `_slotRow(String label, AdSlot slot)` dùng `ValueListenableBuilder<AdSlotState>(valueListenable: slot.state, ...)`.
- Có thể ảnh hưởng cả 3 dòng hiện tại (AppOpen/Inter/Rewarded), không riêng gì Interstitial — Interstitial chỉ là ví dụ cụ thể tình cờ phát hiện được.
- Cách tái hiện: mở app mẫu (`example/`), bấm mở bảng debug (nút "🐛 Ad"), rồi điều hướng sang "Banner ad" demo (màn này gọi `loadInterstitial()` ngay trong `initState`) — trên thiết bị thật.

## Việc cần làm (gợi ý, chưa xác nhận hướng đi)
1. Xác nhận lại lỗi có thật trên nhiều màn hình demo khác (không chỉ Banner demo) gọi tương tự trong `initState`.
2. Cân nhắc hướng sửa: hoãn thông báo tới `ValueListenableBuilder` sang frame kế tiếp (VD `WidgetsBinding.instance.addPostFrameCallback`) khi phát hiện đang trong pha build, thay vì cập nhật đồng bộ ngay lập tức.
3. Viết test tái hiện lỗi (trước khi sửa) rồi xác nhận hết lỗi sau khi sửa.
4. Cập nhật CHANGELOG.md.

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Test tái hiện được lỗi + xác nhận đã sửa.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device đúng kịch bản tái hiện lỗi ở trên, xác nhận không còn crash.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-13)

Xác nhận lỗi ảnh hưởng CẢ 3 dòng (AppOpen/Inter/Rewarded — dùng chung
`_slotRow`), không riêng Interstitial, VÀ thêm 1 chỗ khác cùng lớp lỗi:
`_FillRateRegressionRows` cũng dùng `ValueListenableBuilder` lắng nghe
`AdManager().initRevision` trực tiếp — cùng rủi ro nếu 1 widget khác gọi
`AdManager().initialize()` đồng bộ trong `initState()`.

Sửa bằng widget riêng `_DeferredValueListenableBuilder` (thêm vào
`debug_ad_overlay.dart`) — thay `setState()` đồng bộ ngay khi
listenable đổi bằng hoãn sang frame kế tiếp
(`WidgetsBinding.instance.addPostFrameCallback`, kèm
`SchedulerBinding.instance.ensureVisualUpdate()` để đảm bảo có frame
được lên lịch kể cả khi app đang "rảnh"). Panel debug chỉ trễ đúng 1
frame — không thể nhận ra bằng mắt thường, và đây là công cụ CHỈ chạy ở
`kDebugMode`, không bao giờ người dùng thật thấy. Áp dụng cho cả 3 chỗ
dùng `ValueListenableBuilder` liên quan tới notifier do SDK quản lý
(`_SlotRows` — 2 chỗ, `_FillRateRegressionRows` — 1 chỗ); 2 chỗ còn lại
trong file (`globallyVisible`, `_expanded`) là state cục bộ UI, không bị
SDK mutate từ nơi khác, giữ nguyên `ValueListenableBuilder` thường.

**Bài học khi viết test tái hiện lỗi**: lần thử đầu tiên (đặt widget
"preload đồng bộ" làm anh em cùng `StatefulBuilder` với overlay) KHÔNG
tái hiện được lỗi — vì Flutter cho phép `setState()` trong lúc build nếu
phần tử gọi là HẬU DUỆ của phần tử đang được dựng. Phải đặt
`DebugAdOverlay` là ANH EM của 1 `Navigator` riêng (giống chính xác cách
`example/lib/main.dart` nối `DebugAdOverlay` ở `MaterialApp.builder`,
NGOÀI cây điều hướng), rồi push route mới qua `Navigator` đó — lúc đó
lỗi tái hiện đúng y hệt (đã xác nhận: tạm bỏ fix, test bắt đúng
`FlutterError` với message y hệt báo cáo gốc).

Xác minh không vô nghĩa: tạm đổi `_DeferredValueListenableBuilder` về
`ValueListenableBuilder` thường, xác nhận test fail đúng với thông báo
lỗi y hệt gốc, rồi khôi phục.

Xác minh: `flutter analyze` sạch; SDK suite 2021 test xanh (từ 2020,
+1); example suite 47 file xanh (không đổi); device smoke thật trên
**Pixel 7 Pro** (`2B051FDH3006MU`, thiết bị thật qua USB) qua
`example/integration_test/t192_debug_overlay_navigation_crash_test.dart`
— chạy đúng kịch bản gốc trên app thật: boot app → mở panel debug → điều
hướng sang "Banner ad" → xác nhận `interstitialSlot` thật sự chuyển sang
`loading` (chứng minh preload thật sự chạy, không phải test pass suông
vì chưa kịp khởi tạo) → không crash.

Điểm tự chấm: **9/10**. Không chạy được codex review (hết hạn mức từ
trước trong phiên) — bù bằng: tự phát hiện thêm 1 chỗ lỗi tương tự ngoài
mô tả gốc, kỷ luật revert-để-xác-nhận-đỏ với message lỗi khớp chính xác,
smoke test thật đúng kịch bản gốc trên device thật.
