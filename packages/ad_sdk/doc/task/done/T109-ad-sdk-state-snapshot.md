# T109 — Enhancement: AdSdkStateSnapshot — 1 ValueListenable tổng hợp toàn bộ trạng thái

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `lib/src/core/ad_manager.dart`, `state/ad_slot.dart`, `widget/debug_ad_overlay.dart`, `ad_readiness_splash_controller.dart`

## Vấn đề

Host muốn disable nút/show skeleton hiện phải ghép nhiều `ValueNotifier` và biết chi tiết adapter/widget instance. [đồng thuận 3 nguồn]

## Việc đã làm

- [x] `AdSdkStateSnapshot` (lib/src/state/ad_sdk_state_snapshot.dart, export công khai) — immutable, value equality — + `AdManager().stateSnapshot` (`ValueListenable`): isInitialised/canRequestAds/isOffline/isVipActive/fullscreenBusy.
- [x] Cập nhật coalesced qua `scheduleMicrotask` — nhiều thay đổi nguồn cùng 1 turn đồng bộ chỉ bắn 1 lần notify.
- [x] Test: `test/ad_sdk_state_snapshot_test.dart` (5 test) — giá trị mặc định, 1 nguồn đổi cập nhật đúng, VIP đọc live state khi trigger bởi nguồn khác, coalescing 3 lần đổi cùng turn → 1 notify, equality/hashCode.
- [~] KHÔNG bao gồm trạng thái per-slot (đề cập ở "Vấn đề" gốc nhưng không có trong 5 field liệt kê tường minh) — để tránh mở rộng scope + rủi ro đụng adapter lifecycle nhạy cảm; có thể tách ticket riêng nếu cần sau.
- [x] Không leak: 3 listener mới (`_offlineNotifier`/`_canRequestAdsNotifier`/`initRevision`) gắn ĐÚNG 1 LẦN trong constructor singleton (không bao giờ dispose lại) — cùng pattern đã dùng cho `fullscreenBusy`'s nguồn khác (xem comment "T75"). Phần VIP piggyback trên subscribe/unsubscribe ĐÃ CÓ SẴN quanh `_onVipActiveChanged` (add lúc init, remove lúc destroy/trước reinit) — không thêm subscription mới nào cần tự dọn, nên không có bề mặt leak mới để test runtime riêng.

Test cuối: 1383 pass (từ baseline 1378 + 5 test mới), `flutter analyze` sạch.
