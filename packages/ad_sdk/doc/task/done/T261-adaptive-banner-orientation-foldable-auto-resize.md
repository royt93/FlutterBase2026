# T261 — Adaptive Banner Tự Động Co Giãn Kích Thước Khi Xoay Màn Hình Hoặc Thiết Bị Gập

- **Loại:** Enhancement / UX
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (KẾT LUẬN: ALREADY IMPLEMENTED & VERIFIED — ĐÃ CÓ ĐẦY ĐỦ TRONG CODEBASE)

## Bối cảnh & Kết quả Rà soát Mã nguồn Thực tế (2026-10-17)

Yêu cầu ban đầu: *Khi xoay ngang/dọc hoặc mở thiết bị gập (width thay đổi), Banner adaptive phải tự động tính lại kích thước, có debounce 300ms chống giật lag và nạp lại vừa vặn không tràn viền.*

**KẾT LUẬN: TÍNH NĂNG NÀY ĐÃ ĐƯỢC TRIỂN KHAI VÀ BẢO VỆ CHẶT CHẼ TỪ T157 VÀ ROUND-29 AUDIT:**

1. **Cơ chế Layout Observer & Debounce 300ms (`lib/src/widget/banner_ad_widget.dart`):**
   - Hằng số `_widthCorrectionDebounceDuration = Duration(milliseconds: 300)`.
   - Widget con `_AdmobWidthObserver` lắng nghe mọi pass layout thực tế (bao gồm xoay màn hình, container cha co giãn, hoặc thiết bị gập).
   - Hàm `_maybeCorrectAdmobWidth()`:
     - So sánh chiều rộng hiện tại `_resolveAdmobWidth(context)` với chiều rộng ad đã nạp trước đó `_admobWidthPx`.
     - Nếu phát hiện thay đổi chiều rộng, kích hoạt debounce 300ms để đợi animation layout ổn định.
     - Sau khi ổn định, gọi `AdManager().disposeBannerInstance(this)` để hủy sạch ad cũ, và gọi `_initBanner(context)` để nạp Banner adaptive mới khớp hoàn hảo với chiều rộng màn hình/container mới.
2. **Phía AppLovin MAX:**
   - AppLovin `MaxAdView` hỗ trợ co giãn kích thước adaptive ở tầng native (`isAdaptiveBannerEnabled: true`), nên SDK chủ động không hủy view để tối ưu hiệu năng và giữ nguyên impression.
3. **Bộ test tự động đã xác minh (`test/banner_ad_widget_test.dart`):**
   - `a width change reloads at the new width instead of keeping the ad sized for the old one` (PASS).
   - `an unrelated dependency change with the same width does not reload` (PASS).
   - `rapid surface-width changes settle on one final AdMob reload` (PASS).
4. **Quyết định:** Đóng task dưới dạng **ALREADY IMPLEMENTED & VERIFIED**.

## Acceptance Criteria

- [x] Banner tự động tính lại kích thước và hiển thị vừa vặn khi xoay ngang/dọc (đã có từ T157).
- [x] Có debounce 300ms chống giật lag khi xoay màn hình liên tục (đã có từ T157).
- [x] Không rò rỉ banner instance cũ khi tải lại kích thước mới (`disposeBannerInstance` được gọi trước khi reload).
- [x] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.
