# T107 — Enhancement: AdPlacement typed xuyên suốt load/show/widget

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `lib/src/widget/banner_ad_widget.dart`, `mrec_ad_widget.dart`, `native_ad_widget.dart`

## Vấn đề

`AdPlacement` đã tồn tại nhưng nhiều entry point vẫn nhận string/default placement ở các tầng khác nhau, làm host dễ typo và khó tái sử dụng cấu hình per-placement. [đồng thuận 3 nguồn]

## Đã đọc kỹ trước khi làm (thu hẹp scope đúng, tránh làm thừa)

`AdManager`'s `load*`/`show*` (core/ad_manager.dart) và `AdScreenState`'s
`showInterstitialAd`/`showRewardedAd`/`showAppOpenAd` (core/ad_screen.dart)
**đã** nhận `AdPlacement` typed từ trước — không có string overload nào cần
deprecate ở 2 tầng đó. Khoảng trống thật chỉ nằm ở 3 WIDGET: `BannerAdWidget`,
`MrecAdWidget`, `NativeAdWidget` hoàn toàn không có tham số `placement` —
mọi AppLovin `AdClickEvent` chúng phát ra hard-code `AdPlacement.unspecified`.

## Việc đã làm

- [x] Thêm `placement` (mặc định `AdPlacement.unspecified`, không breaking)
      cho cả 3 constructor: `BannerAdWidget`, `MrecAdWidget`, `NativeAdWidget`.
- [x] Truyền xuyên suốt tới `AdClickEvent` mà mỗi widget phát khi AppLovin
      báo click (trước đó luôn là `unspecified` bất kể context thật).
- [x] Test: `banner_ad_widget_test.dart`/`mrec_ad_widget_test.dart`/
      `native_ad_widget_test.dart` — group "T107 — placement" (mặc định +
      custom value) cho cả 3 widget.
- [ ] Factory/const catalog cho host — không cần thêm, `AdPlacement`'s các
      hằng số sẵn có (`.home`, `.shop`, ...) đã đóng vai trò này.
- [ ] "Deprecate dần overload string" — không áp dụng, không có string
      overload nào tồn tại ở tầng widget hay manager để deprecate.

Test cuối: 1378 pass (từ baseline 1372 + 6 test mới), `flutter analyze` sạch.
