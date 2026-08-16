# T65 — Nhiều `NativeAdWidget`/`BannerAdWidget` cùng lúc trên AdMob có thể xung đột do adapter lưu instance singleton

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/adapters/admob_adapter.dart:200-204,1039-1047,1165-1172,1268-1272`, `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:130-152`, `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:234-273`

## Vấn đề (Why — CONFIRMED)
`AdMobAdapter` lưu trữ `_bannerAd`, `_mrecAd`, `_nativeAd` dưới dạng singleton field trên instance adapter (`admob_adapter.dart:200-204`). Khi widget layer render qua `buildAdmobBannerView()` (dòng 1039-1047), `buildAdmobMrecView()` (dòng 1165-1172), hoặc `buildAdmobNativeView()` (dòng 1268-1272), adapter luôn trả về `AdWidget` bọc cùng 1 instance `AdWithView`.

Trong `google_mobile_ads` (`lib/src/ad_containers.dart:671-704`), `_AdWidgetState` theo dõi `instanceManager.isWidgetAdIdMounted(adId)`. Nếu cùng một ad object được mount vào từ 2 `AdWidget` cùng lúc, `build()` sẽ throw trực tiếp `FlutterError: 'This AdWidget is already in the Widget tree'`.

Hậu quả:
1. Hai `BannerAdWidget` hoặc hai `MrecAdWidget` trên cùng một màn hình (hoặc trong cùng widget tree) sẽ bị crash ngay lập tức.
2. `NativeAdWidget` không có cơ chế `RouteAware` ẩn view khi route bị che (như `BannerAdWidget` có `_admobIsTop`), nên nếu 2 màn hình cùng chứa `NativeAdWidget` nằm trong navigation stack, màn hình thứ 2 mount lên sẽ crash `FlutterError`.

## Việc cần làm
- [x] **Verify trước:** Đã đọc trực tiếp source `admob_adapter.dart`, `native_ad_widget.dart`, `banner_ad_widget.dart` và `google_mobile_ads/src/ad_containers.dart`. Bug **CONFIRMED** — `AdMobAdapter` dùng singleton `AdWithView` và `AdWidget` ném assertion/error khi mount trùng instance.
- [ ] Nếu confirm: đổi lưu trữ trong adapter từ singleton sang keyed-by-widget-instance (map theo id/key) hoặc quản lý lifecycle multi-instance tương thích.
