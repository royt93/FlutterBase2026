# T57 — `_admobIsTop` không bao giờ `true` khi widget mount trên route đã active (banner/mrec AdMob trắng)

- **REQ:** audit round mới 2026-08-15 (agy + Claude subagent, "đã verify độc lập" — **verify đó SAI**, xem Kết luận)
- **Priority:** P0 · **Status:** ✅ done — **REFUTED**, không có bug, đã thêm test khoá lại hành vi đúng (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:53,116-133,236-244`, `packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart:43,117,216-224`, `packages/ad_sdk/test/banner_ad_widget_test.dart`, `packages/ad_sdk/test/mrec_ad_widget_test.dart`

## Vấn đề (Why, claim gốc)
`_admobIsTop` khởi tạo `false`, chỉ set `true` qua `RouteAware.didPush()`/`didPopNext()`. Claim gốc: khi widget mount trên route ĐÃ active từ trước (vd Home/Splash), `RouteObserver.subscribe()` không tự fire `didPush()` cho route đó — "hành vi chuẩn Flutter". Claim này được 2 audit độc lập (agy, Claude subagent) + 1 pass verify riêng đều xác nhận CONFIRMED, không ai kiểm tra lại source Flutter SDK thật.

## Kết luận — REFUTED (2026-08-15, phát hiện qua TDD)
Theo TDD, viết test trước khi sửa code: mount `BannerAdWidget`/`MrecAdWidget` trực tiếp làm `home:` (không push route nào), giả lập adapter AdMob đã `isLoaded=true`/`visible=true`, assert `find.text('Ad')` (chỉ render khi banner thật sự hiển thị, không phải placeholder). **Cả 2 test pass NGAY LẬP TỨC không cần sửa 1 dòng code nào.**

Đọc lại Flutter SDK thật (`/Users/LoiTP/development/flutter/packages/flutter/lib/src/widgets/routes.dart:2431-2436`):
```dart
void subscribe(RouteAware routeAware, R route) {
  final Set<RouteAware> subscribers = _listeners.putIfAbsent(route, () => <RouteAware>{});
  if (subscribers.add(routeAware)) {
    routeAware.didPush();
  }
}
```
`RouteObserver.subscribe()` **LUÔN LUÔN** gọi `didPush()` ngay khi subscribe thành công — không điều kiện theo `route.isCurrent`, không chỉ áp dụng cho route "vừa mới push". Claim gốc "RouteObserver không tự fire didPush() cho route đã active — hành vi chuẩn Flutter" là **sai về chính hành vi Flutter thật**, không phải chỉ sai phạm vi. `_admobIsTop` luôn được set `true` đúng ngay trong `didChangeDependencies` → `adRouteObserver.subscribe()` → `didPush()` đồng bộ, dù widget mount trên route mới toanh hay route đã active từ trước.

**Bài học:** 2 audit + 1 verify độc lập đều tự tin khẳng định 1 "hành vi chuẩn Flutter" mà không ai thực sự đọc source Flutter SDK để xác nhận — TDD (viết test thật, watch nó pass ngay thay vì fail) là cách bắt được lỗi giả định này, review code/mô tả suông không đủ.

## Việc đã làm
- [x] Thêm test `banner_ad_widget_test.dart`: "AdMob banner mounted on an already-current route (never pushed) still renders the ad, not the placeholder".
- [x] Thêm test tương tự `mrec_ad_widget_test.dart`.
- [x] `flutter test` (packages/ad_sdk): 702/702 pass, không regression.
- [x] Không sửa `banner_ad_widget.dart`/`mrec_ad_widget.dart` — hành vi hiện tại đã đúng.
