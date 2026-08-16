# T100 — AppLovin `NativeAdWidget` chưa re-check gate khi subtree bị tạo lại (tách từ T62)

- **REQ:** tách từ T62 sau khi T62's root cause thật (deadlock mount) được fix (2026-08-15)
- **Priority:** P2 (giờ mới có ý nghĩa để test, vì trước đây view chưa từng mount lần nào) · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart` (`_allowed`, `build()`)

## Vấn đề (Why, chưa verify — claim gốc của T62 trước khi phát hiện deadlock)
`_allowed` được set `true` một lần qua gate ban đầu (consent/cooldown/cap/network) và không có cơ chế re-check khi widget rebuild sau đó. Trước khi T62 fix xong, câu hỏi này vô nghĩa vì `MaxNativeAdView` chưa từng mount lần nào — giờ view đã mount thật, có thể verify: nếu consent bị revoke/cap đổi trạng thái SAU khi `_allowed=true` và trước khi `MaxNativeAdView` load xong, widget có tạo/giữ view dù gate đã đổi không.

## Việc cần làm
- [x] Viết test: gate pass → `_allowed=true` → revoke consent / trigger cap TRƯỚC khi `MaxNativeAdView` báo loaded → xác nhận hành vi thật (có tiếp tục hiển thị native view đã mount, hay ẩn/dispose).
- [x] Nếu xác nhận có vấn đề: thêm re-check gate hoặc ẩn view khi gate đổi giữa chừng.
- [x] Nếu không tái hiện được / hành vi hiện tại chấp nhận được: đóng ticket, ghi bằng chứng.

## Đã làm (2026-08-16)

**Kết luận: hành vi hiện tại chấp nhận được, đóng ticket không sửa code —
đúng nhánh "không tái hiện được bug thật" của chính ticket đề ra.** Bằng
chứng qua 2 test mới trong `test/native_ad_widget_test.dart` (group "T100 —
gate re-check when state changes mid-flight"):

1. `consent revoked after the gate passes but before the native ad finishes
   loading` — mount widget (gate pass, load request đã gửi đi), revoke
   consent NGAY SAU đó bằng `debugCanRequestAds = false`, rồi fire
   `isLoaded.value = true` (mô phỏng ad network trả kết quả cho request ĐàGỬI
   TRƯỚC). Kết quả: ad vẫn hiển thị bình thường.
2. `a later consent revoke does not stop a SUBSEQUENT rebuild...` — xác nhận
   gate VẪN được re-check đầy đủ mỗi lần `_initNative()` chạy lại (không
   phải bug "cache vĩnh viễn") — chỉ là 1 khi ĐÃ pass rồi thì không có cơ chế
   nào REVOKE lại `_allowed` khi trạng thái đổi.

**Vì sao chấp nhận được, không phải bug:** kiểm tra chéo
`banner_ad_widget.dart`/`mrec_ad_widget.dart` — CẢ HAI cũng chỉ check
`canRequestAds` 1 lần lúc gate (init), KHÔNG reactive trong `build()`. Đây là
thiết kế nhất quán toàn SDK: consent/cap là gate ở THỜI ĐIỂM REQUEST, không
phải enforce ngược lên request đã gửi — khớp với cách ad network thật hoạt
động (request đã rời máy thì revoke consent sau đó không hủy ngược được).
Sửa riêng cho native sẽ tạo BẤT NHẤT với banner/mrec, không phải fix. Ca
DUY NHẤT có reactive gate là VIP (qua `vipListenable` trong `build()`) — đã
test từ trước ("VIP active → native ad collapses"), không thuộc scope ticket
này.

**Phát hiện phụ (ghi nhận, KHÔNG fix — ngoài scope ticket P2 này):**
`AdManager.canLoadNative()` chỉ là cooldown per-key (`_lastNativeLoadAtByKey`),
native **không có** daily/hourly safety cap nào cả (khác hẳn interstitial/
rewarded/appOpen đi qua `AdSafetyConfig.canShowFullscreenAd()` +
per-placement cap T92) — nên "trigger cap" trong đề bài gốc không có gì để
trigger cho native ngoài cooldown đã test. Đáng làm 1 ticket riêng nếu muốn
native cũng có daily/hourly cap giống các loại ad khác.
- `flutter analyze`: No issues found! `flutter test`: 833/833 pass.
