# T65 — Nhiều `NativeAdWidget`/`BannerAdWidget` cùng lúc trên AdMob có thể xung đột do adapter lưu instance singleton

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/adapters/admob_adapter.dart:200-204,1039-1047,1165-1172,1268-1272`, `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:130-152`, `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:234-273`

## Vấn đề (Why — CONFIRMED)
`AdMobAdapter` lưu trữ `_bannerAd`, `_mrecAd`, `_nativeAd` dưới dạng singleton field trên instance adapter (`admob_adapter.dart:200-204`). Khi widget layer render qua `buildAdmobBannerView()` (dòng 1039-1047), `buildAdmobMrecView()` (dòng 1165-1172), hoặc `buildAdmobNativeView()` (dòng 1268-1272), adapter luôn trả về `AdWidget` bọc cùng 1 instance `AdWithView`.

Trong `google_mobile_ads` (`lib/src/ad_containers.dart:671-704`), `_AdWidgetState` theo dõi `instanceManager.isWidgetAdIdMounted(adId)`. Nếu cùng một ad object được mount vào từ 2 `AdWidget` cùng lúc, `build()` sẽ throw trực tiếp `FlutterError: 'This AdWidget is already in the Widget tree'`.

Hậu quả:
1. Hai `BannerAdWidget` hoặc hai `MrecAdWidget` trên cùng một màn hình (hoặc trong cùng widget tree) sẽ bị crash ngay lập tức.
2. `NativeAdWidget` không có cơ chế `RouteAware` ẩn view khi route bị che (như `BannerAdWidget` có `_admobIsTop`), nên nếu 2 màn hình cùng chứa `NativeAdWidget` nằm trong navigation stack, màn hình thứ 2 mount lên sẽ crash `FlutterError`.

## Việc cần làm
- [x] **Verify trước:** Đã đọc trực tiếp source `admob_adapter.dart`, `native_ad_widget.dart`, `banner_ad_widget.dart` và `google_mobile_ads/src/ad_containers.dart`. Bug **CONFIRMED** — `AdMobAdapter` dùng singleton `AdWithView` và `AdWidget` ném assertion/error khi mount trùng instance.
- [x] Đổi lưu trữ trong adapter từ singleton sang keyed-by-widget-instance (map theo `Object` key = `this` của mỗi widget `State`).

## Đã làm (2026-08-16)

**Scope thật lớn hơn ticket gốc:** lúc scoping phát hiện `AppLovinAdapter` cũng bị đúng lỗi singleton này ở banner/mrec (`_bannerAdViewId`/`_mrecAdViewId` là 1 `ValueNotifier` chung, 1 lần `preloadWidgetAdView`) — ticket gốc chỉ nêu AdMob. Riêng AppLovin **native** không bị (mỗi `NativeAdWidget` tự build `MaxNativeAdView` riêng, không qua adapter-level state chung). User chọn fix full 6 tổ hợp (banner/mrec/native × AdMob/AppLovin) để hỗ trợ N instance thật, không chỉ chặn crash.

**Thiết kế "keyed-by-instance":** mỗi widget `State` tự tạo `final Object _instanceKey = Object();` trong `initState()`, truyền key này vào mọi call adapter/AdManager. Map `Map<Object, T>` lazy-tạo cho: `AdSlot`, `BannerListenables` (`isLoaded`/`hasError`/`adSize`/`autoRefreshEnabled`/`visible`), và live ad object (`BannerAd`/`NativeAd` phía AdMob; `adViewId` phía AppLovin). `disposeXInstance(key)` gọi trong `dispose()` để giải phóng map entry, tránh leak khi widget unmount (native trong `ListView` scroll ra ngoài). Cố ý **giữ global** phần safety/rate-limit (`canLoadBanner`/`recordBannerLoad`, `AdSafetyConfig` cap ngày/giờ/session) — đây là ngân sách chính sách toàn app, key theo instance sẽ cho phép host bypass cap bằng cách mount thêm widget.

**3 phase, 1 commit/phase** (đúng plan đã duyệt):
1. `2267801` — Native (AdMob + AppLovin), phase nhỏ nhất, giá trị cao nhất (feed ads). Phát hiện thêm bug rò rỉ shimmer-state chéo instance ở AppLovin (`isLoaded`/`hasError` bị share dù native tự thân không crash) — fix chung 1 lần.
2. `32a03af` — Banner (AdMob + AppLovin), thiết lập full pattern keyed gồm cả map `adViewId` AppLovin. Regression phát hiện khi bỏ hẳn 3 call site `preloadBanner()` không-key (SDK-init/VIP-expiry/reconnect) — vỡ test `connectivity_refill_test`/`connectivity_resilience_test` (assert `preloadBannerCalls > 0`). Fix: thêm sentinel key `_globalBannerWarmupKey` cho các call site "chưa có widget key" này (trade-off: double-load lãng phí ở case 1-banner phổ biến, nhưng không mất chức năng).
3. `8c367e9` — MREC (AdMob + AppLovin), cơ học lặp lại pattern (2), thêm sentinel `_globalMrecWarmupKey` tương tự.

**Test:** ~20 file test cập nhật sang signature `key` mới; thêm test "2 instance đồng thời, độc lập state" cho mỗi loại × mỗi provider ở cả tầng adapter (`admob_adapter_test.dart`, `applovin_adapter_test.dart`) và tầng widget (`native_ad_widget_test.dart`, `banner_ad_widget_test.dart`, `mrec_ad_widget_test.dart`). `banner_leak_regression_test.dart` sửa assertion cũ (`<=2 load/25 cycle`, dựa vào cooldown global cũ tình cờ che leak) sang assertion đúng bản chất: mỗi cycle độc lập load 1 lần + map rỗng sau dispose hết.

**Phase 4 — integration test + smoke test thiết bị thật (2026-08-16):**
- Thêm `example/integration_test/multi_instance_ad_test.dart` — 3 test, mount 2 instance mỗi loại (Banner/MREC/Native) qua app thật (`app.main()`), assert `findsNWidgets(2)` + `tester.takeException()` null.
- Thêm section "instance thứ 2" vào 3 demo page có sẵn (`BannerDemoPage`, `MrecDemoPage`, `NativeDemoPage` trong `example/lib/main.dart`) — vừa làm màn hình thật cho integration test, vừa là demo trực quan cho tính năng.
- Chạy trên **Pixel 7 Pro thật** (`2B051FDH3006MU`, Android 17): `flutter test integration_test/multi_instance_ad_test.dart -d 2B051FDH3006MU` — lần đầu 1 test native treo do flake app-launch đã biết (xem ghi chú CI trong CLAUDE.md, không phải bug T65), lần retry: **3/3 pass, "All tests passed!"**.
- Build debug APK, cài + mở tay qua `mcp__mobile__*`, chụp screenshot cả 3 demo page: mỗi page hiện đúng 2 instance ad cạnh nhau, load độc lập (1 cái xong trước, cái kia còn shimmer) — đúng ý đồ thiết kế, không đè lên nhau. `mobile_list_crashes` rỗng ở cả 3 lần check.
- `flutter test` full suite `packages/ad_sdk`: **722/722 pass**, `flutter analyze` (cả package + example) sạch.

**Kết quả:** N instance đồng thời hoạt động thật cho cả 6 tổ hợp (banner/mrec/native × AdMob/AppLovin), verify bằng unit + widget + integration test + smoke test thiết bị thật.
