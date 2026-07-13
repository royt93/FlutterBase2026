# T33 — Banner không có UI state "offline" riêng biệt

- **REQ:** 2 (work có mạng / không có mạng)
- **Priority:** P1 · **Severity:** LOW-MEDIUM · **Status:** ✅ done (2026-07-13)
- **Files:** `packages/ad_sdk/lib/src/widgets/banner_ad_widget.dart` (dòng ~94-97, 216)

## Vấn đề (Why)
Khi offline, banner trả về `SizedBox.shrink()` — **y hệt** trường hợp VIP-active, consent-chưa-có, hoặc đang cooldown. Không thể phân biệt bằng mắt "banner đang ẩn vì offline" với "banner ẩn vì lý do khác" (VIP, consent, safety cap). Reload khi có mạng lại đã hoạt động đúng (không bị storm postFrameCallback), chỉ thiếu tín hiệu UI khi đang ở trạng thái offline.

## Giải pháp đề xuất
- Thêm 1 enum state riêng (vd. `BannerVisualState.offline`) tách khỏi các state ẩn khác.
- Quyết định UI cụ thể cần hỏi ý kiến sản phẩm: có thể là placeholder mờ nhỏ, hoặc vẫn `SizedBox.shrink()` nhưng expose callback/state để host app tự quyết định hiển thị gì (đơn giản hơn, tránh SDK áp đặt UI).
- Khuyến nghị: expose 1 `ValueListenable<bool> isOfflineListenable` hoặc tương tự thay vì SDK tự vẽ UI offline — giữ đúng triết lý "SDK cung cấp signal, host app quyết định hiển thị" như đã làm với VIP (`activeListenable`).

## Acceptance criteria
- [ ] Có cách phân biệt được (qua state/listenable) banner đang ẩn vì offline vs vì lý do khác.
- [ ] Không phá vỡ hành vi hiện tại (ẩn hoàn toàn) nếu host app không quan tâm state mới.

## Test
Test case mới trong `banner_ad_widget_test.dart`: simulate offline → assert state/listenable phản ánh đúng "offline", khác với case VIP-active/consent-denied.

## Kết quả
Đi theo hướng khuyến nghị: thêm `ValueListenable<bool> isOfflineListenable` vào `AdManager` (mirror `VipManager.activeListenable`), không sửa `banner_ad_widget.dart` — offline check hiện tại chỉ `return` sớm, không set state riêng nên tách tín hiệu không đụng gating logic cũ. `_offlineNotifier` được seed đúng ở `_startConnectivityWatch()`, cập nhật trong `_onConnectivityChanged`, và reset về `false` trong `destroy()`. Test mới `group('isOfflineListenable (T33)')` trong `ad_manager_core_test.dart` dùng seam `debugConnectivityChanged` xác nhận flip true/false đúng theo kết nối. SDK không tự vẽ UI offline — host app tự quyết định hiển thị gì, giữ nguyên hành vi ẩn hoàn toàn mặc định.

## Giới hạn đã biết
Banner vẫn ẩn hoàn toàn khi offline như trước — nếu host app không lắng nghe `isOfflineListenable` thì không có gì thay đổi về UI (đúng ý đồ "opt-in signal", không phải fix bắt buộc phải dùng). Chưa có test end-to-end cho `banner_ad_widget.dart` render UI theo signal này vì UI cụ thể do host tự quyết định, ngoài phạm vi SDK.
