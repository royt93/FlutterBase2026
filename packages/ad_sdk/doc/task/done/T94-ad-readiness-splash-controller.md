# T94 — Ý tưởng: `AdReadinessSplashController`/widget orchestration splash chính thức

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/README.md:73,139`, `packages/ad_sdk/lib/src/core/ad_manager.dart:1061`

## Ý tưởng
README yêu cầu app tự set navigator key, route observer, ATT, UMP, init SDK, app-open/splash flow đúng thứ tự — nhiều bước dễ làm sai thứ tự. Một controller/widget first-party official hoá flow này sẽ giảm lỗi integration, giúp app mới có flow production-ready nhanh hơn.

## Việc cần làm (đề xuất, chưa code)
- [x] Thiết kế widget/controller gói gọn thứ tự bước README yêu cầu, vẫn cho phép app tuỳ biến UI splash riêng.

## Đã làm (2026-08-16)

**Thiết kế:** `AdReadinessSplashController` — 1 class thuần (không phải Widget) orchestrate toàn bộ logic README Step 5 đã mô tả tay: `markSplashActive`/`incrementSplashCount`, subscribe `SimpleEventBus` TRƯỚC `initialize()`, hard-cap timer, guard re-entrant splash (`countInitSplashScreen > 1`), `AdLoadingDialog.showAdBuffer()` + `showAppOpenAd(bypassSafety: true)`. Host chỉ gọi `controller.start(context, onReady: ...)` trong `initState()` — UI splash 100% tự do (không dictate bất kỳ widget nào).

**Phát hiện thật khi verify source trước khi code:** `SimpleEventBus` (`event_bus.dart`) ĐÃ replay `_lastEvent` cho listener đăng ký muộn (comment "F1" trong code) — README's cảnh báo "⚠️ Subscribe BEFORE calling initialize() — SimpleEventBus only delivers fire events to listeners registered before the fire" ĐÃ LỖI THỜI (stale), không còn đúng với code thật. Sửa lại wording README cho khớp source hiện tại.

**Bug thật phát hiện khi TDD:** `dispose()` ban đầu chỉ cancel timer CỦA CONTROLLER, không đụng đến timer NỘI BỘ của `AdManager` (`_splashBudgetTimer`, tự arm bên trong `markSplashActive()`) — Flutter test framework bắt lỗi thật ("A Timer is still pending even after the widget tree was disposed"). Fix root cause: `dispose()` giờ cũng gọi `AdManager().markSplashInactive()` — vừa dọn timer nội bộ, vừa tránh rò rỉ trạng thái "splash đang active" nếu widget bị dispose mà `onReady` chưa từng fire (vd app bị kill giữa chừng).

**Bug format phát hiện tình cờ khi thêm docs:** README có 1 code fence bị hỏng thật — section "Per-platform ad-unit ids" đã bị chèn NHẦM VÀO GIỮA class `_SplashScreenState` (đóng fence sớm), khiến phần còn lại của class (`_showSplashAppOpen`/`_goHome`) render thành text thường thay vì code block trên GitHub/pub.dev. Sửa lại: đưa "Per-platform ad-unit ids" ra sau khi class đã đóng đúng, thêm section mới "AdReadinessSplashController" ngay sau.

TDD: 3 test (`ad_readiness_splash_controller_test.dart`) — hard cap tự fire `onReady` khi không có gì khác resolve kịp, guard re-entrant splash short-circuit, `dispose()` trước khi hard cap bắn thì `onReady` không bao giờ fire (xác nhận qua chính lỗi framework thật bắt được ở trên).

README + CHANGELOG cập nhật đầy đủ.

`flutter test`: 797/797 pass (2 lần), `flutter analyze` sạch.
