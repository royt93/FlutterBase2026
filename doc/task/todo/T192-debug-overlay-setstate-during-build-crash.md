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
