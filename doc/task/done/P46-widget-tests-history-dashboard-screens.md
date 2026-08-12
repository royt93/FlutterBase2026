# P46 — Viết widget test cho `history_screen.dart` và `network_dashboard_screen.dart` (0% coverage)

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập)
- **Files:** `presentation/history_screen.dart`, `presentation/network_dashboard_screen.dart`, `test/`

## Vấn đề
2 screen này chưa có widget test nào trong `test/` (khác với các screen khác đã có wave-test tương ứng, xem `doc/task/README.md` cho danh sách wave hiện có) — regression về filter tab, export flow, hoặc render dashboard sẽ không bị bắt bởi CI.

## Việc cần làm (đề xuất, chưa code)
- `wave8_history_screen_test.dart` (hoặc số wave tiếp theo): render, đổi tab Day/Week/Month, verify list lọc đúng (đối chiếu [[P39-history-controller-date-filter-exclusive]] sau khi fix).
- `wave8_network_dashboard_screen_test.dart`: render, verify hiển thị SSID/public IP/gateway (mock service), verify guard `Get.put` sau khi fix P03.

## Acceptance criteria
- [ ] Cả 2 screen có ít nhất 1 test render + 1 test tương tác qua code thật (không mirror logic).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp chung 1 sprint test-debt với [[P06-wave6-room-tag-test-mirrors-logic]] và [[P13-wave7-test-coverage]], làm cả 3 cùng lúc.
