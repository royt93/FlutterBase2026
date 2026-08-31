# T109 — Enhancement: AdSdkStateSnapshot — 1 ValueListenable tổng hợp toàn bộ trạng thái

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/core/ad_manager.dart`, `state/ad_slot.dart`, `widget/debug_ad_overlay.dart`, `ad_readiness_splash_controller.dart`

## Vấn đề

Host muốn disable nút/show skeleton hiện phải ghép nhiều `ValueNotifier` và biết chi tiết adapter/widget instance. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Public immutable `AdSdkStateSnapshot` + `ValueListenable`: init/consent/offline/VIP/fullscreen-busy + trạng thái từng slot
- [ ] Cập nhật coalesced theo microtask (tránh rebuild dư thừa)
- [ ] Test: đổi 1 trong các trạng thái nguồn, xác nhận snapshot cập nhật đúng 1 lần, không leak listener nội bộ
