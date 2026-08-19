# T12 — Banner: chống postFrameCallback dồn + dispose-trước-recreate

- **REQ:** 3 (no memory leak)
- **Priority:** P1 · **Severity:** HIGH · **Status:** ✅ done (2026-07-05)

## Kết quả
- Thêm cờ `_initScheduled` trong `BannerAdWidget.build` → chỉ 1 postFrameCallback `_initBanner` pending tại một thời điểm (hết chồng callback khi build lặp lại vì initRevision/parent rebuild).
- Phần "dispose-before-recreate": `loadBannerIfNeeded` đã có `if (_bannerAd != null) return` → **không recreate-without-dispose** (finding agent phần này là false positive). Không đổi thêm.
- Test: `banner_ad_widget_test.dart` "repeated rebuilds trigger exactly one banner load" (fake AdMob adapter đếm load). **269/269 xanh.**
- **Files:** `widget/banner_ad_widget.dart` (`build` `:178-181`, `didChangeDependencies`), `adapters/admob_adapter.dart` (banner load/dispose)

## Vấn đề (Why)
`build()` add postFrameCallback **mỗi lần** rebuild khi `!_allowed && isInitialised` → nhiều `_initBanner`/load chồng nhau (đặc biệt khi `initRevision` đổi). Banner adapter có cửa sổ tạo `_bannerAd` mới trong khi cái cũ đang chờ dispose → rò rỉ/nhầm object.

## Acceptance criteria
- [ ] Cờ `_postFrameCallbackPending` (hoặc chuyển timing sang `didChangeDependencies`) để chỉ có **1** callback init pending tại một thời điểm.
- [ ] Banner adapter dispose object cũ **trước** khi tạo cái mới (đặc biệt khi đổi width/size).
- [ ] Không còn nhiều `loadBannerIfNeeded` chạy song song cho cùng slot.
- [ ] `recordBannerLoad`/cooldown (`:351,192`) vẫn hoạt động.

## Test
- [ ] Widget test: rebuild liên tục → chỉ 1 load được kích hoạt.
