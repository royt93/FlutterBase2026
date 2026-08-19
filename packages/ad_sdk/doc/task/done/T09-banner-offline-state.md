# T09 — Banner offline state + auto-reload

- **REQ:** 2 (work không mạng)
- **Priority:** P1 · **Severity:** HIGH · **Status:** ✅ done (2026-07-05)

## Kết quả & phát hiện
- **"Shimmer forever" là false positive**: khi offline (`!_allowed`), `BannerAdWidget` render `SizedBox.shrink()` — **collapsed, không shimmer, không tốn pin**. Đúng hành vi mong muốn (đa số app collapse ad slot khi offline).
- **Auto-reload khi reconnect** đã hoạt động qua T08: connectivity watch bump `initRevision` → build re-run → post-frame `_initBanner` → load. Verify bằng test.
- Test: `banner_ad_widget_test.dart` "banner collapses offline and reloads on reconnect" (offline → 0 load; reconnect → 1 load), dùng `debugConnectivityChanged` + `debugResetBannerCooldown` (seam mới chống leak cooldown giữa test).
- Không thêm UI "No connection" (tránh scope-creep; host có thể tự thêm nếu muốn). **272 test xanh.**
- **Files:** `widget/banner_ad_widget.dart` (`_initBanner` `:67-94`), `core/ad_manager.dart` (banner accessors `:343-376`)

## Vấn đề (Why)
Khi offline, `banner_ad_widget` return im lặng, `_allowed=false`, hiển thị shimmer/placeholder vô thời hạn, và **không có listener reload** khi mạng về. User không phân biệt được "đang tải" vs "offline".

## Acceptance criteria
- [ ] Có state "offline" riêng cho banner (không nhầm với loading/error).
- [ ] Khi mạng trở lại (dựa listener ở T08) → banner tự `_initBanner`/reload.
- [ ] Placeholder offline gọn (không shimmer chạy mãi gây tốn pin).
- [ ] Tôn trọng VIP/consent guard (không load khi bị suppress).

## Ghi chú kỹ thuật
- Phụ thuộc T08 (connectivity listener). Có thể expose `ValueListenable<bool> bannerOffline` từ AdManager.

## Test
- [ ] Widget test: offline → placeholder offline; online lại → gọi load.
