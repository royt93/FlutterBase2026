# T67 — Reconnect handler không chủ động refill `preloadMrec`/`preloadNative` khi mạng về

- **REQ:** audit round mới 2026-08-15 (claude subagent), verify độc lập 2026-08-15
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (`_onConnectivityChanged` L2917-2942, `_retryRefillAds` L2944-2974), `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart` (`preloadMrec` L1136-1183), `packages/ad_sdk/lib/src/adapters/admob_adapter.dart` (`preloadMrec` L1054-1070 — no-op by design)

## Vấn đề (Why) — CONFIRMED, đã tinh chỉnh phạm vi
Đọc trực tiếp `_onConnectivityChanged` (ad_manager.dart:2917): khi offline→online, handler chỉ gọi `_retryRefillAds()` (appOpen/interstitial/rewarded — L2965-2973, không đụng mrec/native), `_adapter?.preloadBanner()` (L2939), và bump `initRevision` (L2940). Không có lời gọi `preloadMrec()`/`preloadNative()` nào ở đây.

- **AppLovin:** `preloadMrec()` (applovin_adapter.dart:1136) là nơi thật sự fetch cache qua `_bridge.preloadWidgetAdView` — chỉ được gọi ở SDK init (ad_manager.dart:1434) và khi VIP hết hạn (`_onVipActiveChanged`, L1507). Reconnect KHÔNG gọi nó. `MrecAdWidget._buildAppLovin()` (mrec_ad_widget.dart:257) khi `mrecHasError == true` chỉ render `SizedBox.shrink()` — không có logic tự retry khi `initRevision` bump, vì widget's `_initMrec()` chỉ chạy lại lúc `!_allowed.value` (mrec_ad_widget.dart:180), và `_allowed.value` đã set `true` ngay khi lần gọi đầu tiên *được thử* (kể cả nếu load đó sau đó fail) — nên gap này xảy ra bất kể widget đã mounted hay chưa, miễn ad đã từng attempt 1 lần rồi lỗi trong lúc mất mạng.
- **AppLovin `preloadNative()`** (applovin_adapter.dart:1206) là no-op có chủ đích (native ad view AppLovin tự load khi mount, không có bridge preload) — phần "preloadNative" trong tiêu đề ticket không áp dụng cho AppLovin, chỉ áp dụng cho AdMob.
- **AdMob:** `preloadMrec()` (admob_adapter.dart:1054) cũng no-op có chủ đích — MREC AdMob load qua `loadMrecIfNeeded(width)` lúc widget mount. Nhưng khi ad đã load rồi lỗi (offline), recovery duy nhất là `onAppResumed()` (admob_adapter.dart ~L1321-1334: `if (mrec.hasError.value && _mrecAd == null) loadMrecIfNeeded(0)`), tức phải qua lifecycle background→foreground — connectivity reconnect một mình (không kèm app resume) không trigger lại được.
- Không tìm thấy test nào cho path này (`connectivity_refill_test.dart`, `mrec_ad_widget_test.dart`, `native_ad_widget_test.dart` đều không có case reconnect-while-mounted-with-error).

Tóm lại: bug có thật, nhưng nguyên nhân gốc không phải "mounted vs unmounted" như audit gốc mô tả — mà là **reconnect handler hoàn toàn không đụng tới mrec/native state** (không gọi AppLovin `preloadMrec()`, không reset `hasError`/gọi lại `loadMrecIfNeeded`/`preloadNative` cho AdMob), nên bất kỳ mrec/native nào đã lỗi trong lúc mất mạng chỉ hồi phục được khi app resume từ background, không phải khi mạng về trong lúc app vẫn foreground.

## Việc cần làm
- [x] **Verify trước:** test connectivity restore khi KHÔNG có widget mounted, xác nhận preload có tự refill hay không.
- [ ] Nếu confirm: thêm `preloadMrec`/`preloadNative` refill vào `_retryRefillAds`/connectivity-restore handler.
