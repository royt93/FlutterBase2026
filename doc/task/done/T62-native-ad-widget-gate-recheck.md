# T62 — AppLovin native ad bị deadlock: `MaxNativeAdView` không bao giờ mount nên không bao giờ load được

- **REQ:** audit round mới 2026-08-15 (codex) — **mở rộng nghiêm trọng khi làm TDD (2026-08-15)**
- **Priority:** P0 (nâng từ P1 — đây là AppLovin native ads **hoàn toàn không hoạt động** trong production, không phải edge case) · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart` (`_NativeContainer`), `packages/ad_sdk/test/native_ad_widget_test.dart`

## Vấn đề (Why)
**PLAUSIBLE, nhưng claim gốc cần thu hẹp.** `_initNative()` kiểm tra VIP, `canRequestAds`, connectivity và native cooldown tại `native_ad_widget.dart:49-69`, sau đó ghi `_allowed = true` một chiều tại dòng 70-71. Nhánh render tại dòng 109-115 chỉ kiểm tra lại `_allowed` và `isInitialised`; nó không kiểm tra lại `canRequestAds`, connectivity, cooldown/daily cap hoặc `adapter.canReload`. Vì vậy, khi subtree AppLovin được tạo lại trong lúc `_allowed` vẫn `true` (ví dụ adapter/init revision đổi hoặc nhánh view bị remove rồi insert lại), widget không có gate request tại thời điểm tạo view.

Tuy nhiên, cold path hiện tại **không** đúng như mô tả gốc rằng `MaxNativeAdView` được tạo ngay khi `_allowed` bật. `_NativeContainer` chỉ gọi `child()` khi `nativeIsLoaded == true` (`native_ad_widget.dart:185-225`), còn AppLovin adapter khởi tạo `native.isLoaded = false`, và chính callback của `MaxNativeAdView` mới set nó thành `true` (`native_ad_widget.dart:238-261`). Đây là vòng phụ thuộc khiến view AppLovin ban đầu chưa được mount để tự load. Test hiện tại không phát hiện vì tự gán `adapter.native.isLoaded.value = true` tại `native_ad_widget_test.dart:240-242`; test “loads on mount” tại dòng 149-167 chỉ assert `preloadNative()` không được gọi, không assert `MaxNativeAdView` thực sự mount/request.

Do đó ticket vẫn hợp lệ ở mức thiết kế gate tại điểm tạo view, nhưng cần xử lý/kiểm thử cùng cold-mount cycle; không thể kết luận rằng một parent rebuild thông thường tự nó luôn tạo request mới.

## Root cause thật (phát hiện khi làm TDD, nghiêm trọng hơn nhiều claim gốc)
`_NativeContainer` chỉ gọi `child()` (tức mount `_AppLovinMaxNativeView`/`MaxNativeAdView` thật) khi `isLoaded == true`. Nhưng `isLoaded` **chỉ** được set `true` bởi chính `onAdLoadedCallback` của `MaxNativeAdView` — một callback không thể bao giờ fire nếu widget mang nó không bao giờ được build. `AppLovinAdapter.preloadNative()` là no-op có chủ đích (`applovin_adapter.dart:1224`, comment "no-op for AppLovin") — không có đường nào khác để phá vòng lặp này. Kết quả: **`MaxNativeAdView` không bao giờ mount, nên native ad AppLovin không bao giờ load được, trong mọi trường hợp, ở production.** Đây không phải edge case (gate rebuild) như mô tả gốc — đây là native ads AppLovin hoàn toàn không hoạt động.

Test cũ (`native_ad_widget_test.dart`) không bắt được vì tự gán `adapter.native.isLoaded.value = true` TRƯỚC khi assert — chính là "che vòng phụ thuộc" mà bản verify trước đã cảnh báo.

## Đã làm (2026-08-15, TDD)
Viết test trước (RED): mount `NativeAdWidget` với AppLovin provider, gate pass, **không** tự gán `isLoaded=true` — assert `find.byType(MaxNativeAdView)` tìm thấy 1 widget. Fail đúng lý do (không mount). Fix: `_NativeContainer` giờ LUÔN mount `child()`, shimmer chỉ là overlay hiển thị khi `!loaded` (dùng `Stack`), không còn là điều kiện quyết định có mount hay không. `flutter test`: 708/708 pass, `flutter analyze` sạch. Đã xác nhận `_buildAdmob()` (nhánh AdMob) không dùng chung `_NativeContainer` nên không bị ảnh hưởng.

## Còn lại (tách ticket riêng, không mở rộng scope T62)
Claim gốc hẹp hơn ("gate không re-check khi subtree tạo lại trong lúc `_allowed` vẫn true") giờ mới thực sự có ý nghĩa để kiểm chứng (trước đây không có ý nghĩa vì view chưa từng mount lần nào) — chuyển thành **T100** để không trộn 2 root cause khác nhau vào 1 commit.
