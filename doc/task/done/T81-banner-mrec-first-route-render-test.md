# T81 — Thiếu widget test assert render thật (không chỉ đếm call) cho banner/mrec ở route đầu — đi kèm T57

- **REQ:** audit round mới 2026-08-15 (claude subagent + agy)
- **Priority:** P1 · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/test/banner_ad_widget_test.dart`, `packages/ad_sdk/test/mrec_ad_widget_test.dart`

## Vấn đề (Why)
Test hiện tại chỉ assert `adapter.loadBannerIfNeeded`/tương tự được gọi bao nhiêu lần, chưa từng assert widget con thực sự build ra ad thật hay placeholder rỗng khi mount làm `home:` route (không push).

## Đã làm (2026-08-15)
Thêm `testWidgets` mount `BannerAdWidget`/`MrecAdWidget` trực tiếp làm `home:` với provider AdMob (`isLoaded`/`visible` = true), assert `find.text('Ad')` render thật. Viết theo TDD trước khi đụng vào T57 — **cả 2 test PASS NGAY, không cần sửa code** → chứng minh claim gốc của T57 sai (xem `doc/task/done/T57-admob-top-flag-first-route.md` — REFUTED, `RouteObserver.subscribe()` của Flutter SDK luôn gọi `didPush()` ngay khi subscribe, không cần route mới toanh). Test vẫn giữ lại làm regression test khoá đúng hành vi này cho tương lai.

## Acceptance criteria
- [x] Test mới cho `BannerAdWidget` mount làm `home:`.
- [x] Test mới cho `MrecAdWidget` mount làm `home:`.
- [x] `flutter test` (packages/ad_sdk): 702/702 pass.
