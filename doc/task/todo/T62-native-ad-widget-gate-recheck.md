# T62 — AppLovin `NativeAdWidget` không re-check gate khi tạo lại native view

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P1 · **Status:** 🔲 todo — verified, plausible với phạm vi thu hẹp (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:48-78,90-115,158-167,185-225,238-261`; `packages/ad_sdk/test/native_ad_widget_test.dart:149-167,220-247`

## Vấn đề (Why)
**PLAUSIBLE, nhưng claim gốc cần thu hẹp.** `_initNative()` kiểm tra VIP, `canRequestAds`, connectivity và native cooldown tại `native_ad_widget.dart:49-69`, sau đó ghi `_allowed = true` một chiều tại dòng 70-71. Nhánh render tại dòng 109-115 chỉ kiểm tra lại `_allowed` và `isInitialised`; nó không kiểm tra lại `canRequestAds`, connectivity, cooldown/daily cap hoặc `adapter.canReload`. Vì vậy, khi subtree AppLovin được tạo lại trong lúc `_allowed` vẫn `true` (ví dụ adapter/init revision đổi hoặc nhánh view bị remove rồi insert lại), widget không có gate request tại thời điểm tạo view.

Tuy nhiên, cold path hiện tại **không** đúng như mô tả gốc rằng `MaxNativeAdView` được tạo ngay khi `_allowed` bật. `_NativeContainer` chỉ gọi `child()` khi `nativeIsLoaded == true` (`native_ad_widget.dart:185-225`), còn AppLovin adapter khởi tạo `native.isLoaded = false`, và chính callback của `MaxNativeAdView` mới set nó thành `true` (`native_ad_widget.dart:238-261`). Đây là vòng phụ thuộc khiến view AppLovin ban đầu chưa được mount để tự load. Test hiện tại không phát hiện vì tự gán `adapter.native.isLoaded.value = true` tại `native_ad_widget_test.dart:240-242`; test “loads on mount” tại dòng 149-167 chỉ assert `preloadNative()` không được gọi, không assert `MaxNativeAdView` thực sự mount/request.

Do đó ticket vẫn hợp lệ ở mức thiết kế gate tại điểm tạo view, nhưng cần xử lý/kiểm thử cùng cold-mount cycle; không thể kết luận rằng một parent rebuild thông thường tự nó luôn tạo request mới.

## Việc cần làm
- [x] **Verify trước:** đọc lại lifecycle + test hiện có; xác nhận build path không re-check gate, đồng thời phát hiện cold path chưa mount `MaxNativeAdView` khi `nativeIsLoaded` mặc định false.
- [ ] Thêm test chứng minh cold AppLovin path thực sự mount view và test remove/reinsert hoặc destroy→re-init sau khi revoke consent/đóng cap; không dùng cách set `native.isLoaded = true` trước mount để tránh che vòng phụ thuộc.
- [ ] Nếu confirm: thêm re-check gate trong `build()` hoặc chặn tạo view mới khi gate đã đổi.
- [ ] Nếu không tái hiện được: đóng ticket, ghi lại bằng chứng negative.

## Đã verify (2026-08-15)
`flutter test test/native_ad_widget_test.dart test/ad_manager_core_test.dart` pass (97 tests), nhưng suite hiện tại không cover revoke/cap sau `_allowed` và tự mở `nativeIsLoaded` trong compliance test nên không bác bỏ finding trên.
