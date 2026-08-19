# T08 — Connectivity listener → auto-refill khi mạng trở lại

- **REQ:** 2 (work có mạng / không mạng)
- **Priority:** P0 · **Severity:** CRITICAL · **Status:** ✅ done (2026-07-05)
- **Files:** `core/ad_manager.dart` (connectivity watch + `_onConnectivityChanged` + `_startConnectivityWatch`/`_stopConnectivityWatch`), `widget/banner_ad_widget.dart` (reload qua `initRevision`)

## Vấn đề (Why)
SDK chỉ **đọc** `ConnectionNotifierTools.isConnected` khi load; **không** subscribe thay đổi mạng. Offline → mọi load bị skip (`:869,1055,1140`). Khi mạng về, slot rỗng cho tới **retry timer 5 phút** (`_retryIntervalMs`). 5 phút là không chấp nhận được cho yêu cầu "work khi có mạng".

## Acceptance criteria
- [ ] `initialize()` subscribe stream connectivity của `connection_notifier`; `destroy()` huỷ subscribe (không leak).
- [ ] Transition `offline → online` gọi ngay `_retryRefillAds()` + reload banner (không chờ timer 5 phút).
- [ ] Có debounce/throttle chống bão sự kiện flapping (vd gộp trong ~1-2s).
- [ ] Không refill khi VIP active hoặc consent chưa cho phép (giữ guard hiện có).
- [ ] Retry timer 5 phút giữ nguyên làm backstop.

## Ghi chú kỹ thuật
- `connection_notifier` cung cấp stream — kiểm tra API (`ConnectionNotifierTools`/notifier) cho listener.
- Lưu subscription vào field, huỷ trong `destroy()` cạnh `_resumeFallbackTimer`.

## Test — `test/connectivity_refill_test.dart` (7 case, xanh)
- [x] offline→online → refill 3 slot + `preloadBanner` + bump `initRevision`.
- [x] online→online (no transition) → no-op.
- [x] online→offline → không refill.
- [x] flapping → gộp thành 1 refill (debounce).
- [x] VIP active → reconnect không refill.
- [x] chưa init → reconnect no-op.
- [x] widget: listener `initRevision` rebuild khi reconnect (banner reload).

## Phát hiện thêm khi impl
`ConnectionNotifierTools.initialize()` **chưa từng được gọi** (SDK lẫn host) → `isConnected` luôn throw → catch trả `true` → **guard offline chưa bao giờ chạy**. T08 nay gọi `initialize()` trong `_startConnectivityWatch()` (best-effort, try/catch). ⇒ đây cũng là nền cho T10 (isConnected pessimistic).

## Kết quả
- Wire `_connectivitySub` = `ConnectionNotifierTools.onStatusChange` khi init; huỷ ở destroy. Debounce 800ms (test seam `debugReconnectDebounce`). Seam `debugConnectivityChanged` để test không cần native.
- Retry timer 5 phút giữ nguyên làm backstop.
- **244/244 test SDK xanh**, analyze sạch.
