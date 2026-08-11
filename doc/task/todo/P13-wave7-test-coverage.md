# P13 — Viết test thật cho cụm Wave 7 (đang 0 coverage cho phần integration)

- **Priority:** P1 · **Severity:** HIGH · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** claude CLI + subagent đọc source
- **Files:** `benchmark_screen.dart`, `schedule_controller.dart`, `schedule_storage.dart`, `benchmark_settings_storage.dart`, `room_comparison_screen.dart` + `test/wave7_*.dart`

## Vấn đề
Wave 7 (feature mới nhất, đang "in progress" theo `doc/feature.md`) chỉ có test cho các **pure-function con** (`pctOfAdvertised`, `nextFireTime`, `shouldAutoStopByData`...). Toàn bộ persistence (`schedule_storage`, `benchmark_settings_storage`), controller wiring (`schedule_controller`), và rendering (`benchmark_screen`, `room_comparison_screen`) **chưa có widget/integration test nào verify**. Cũng chưa có test riêng cho `server_selector_widget.dart` và data-limit dialog (`_CustomDataLimitDialog` trong `control_panel_widget.dart`).

## Đã verify (2026-08-11, audit vòng 2 — codex CLI)
Một phần đã lỗi thời: `test/wave7_server_selection_test.dart:77` và `test/wave7_data_limit_test.dart:42` đã tồn tại (test server-selection logic + data-limit preset UI). Vẫn thiếu: `benchmark_screen`/`schedule_controller`/`room_comparison_screen` integration/persistence/rendering thật.

## Việc cần làm (đề xuất, chưa code)
- `wave7_benchmark_screen_test.dart` — widget test: render, nhập advertised speed, verify chart/state update.
- `wave7_schedule_controller_test.dart` — unit/widget test: tạo/sửa/xoá schedule, verify `ScheduleStorage` ghi đúng, `nextFireTime` cập nhật đúng khi đổi giờ.
- ~~Test cho `server_selector_widget.dart`~~ (đã có, xem verify note trên).
- Test cho `_CustomDataLimitDialog` (nhập limit, verify `dataLimitMb` cập nhật đúng trong `StressorController`).
- (Liên quan P06) sửa `wave6_room_tag_test.dart` để test qua `RoomComparisonScreen` thật.

## Acceptance criteria
- [ ] Mỗi file/controller kể trên có ít nhất 1 test chạy qua code thật (không mirror logic).
- [ ] `flutter test` xanh toàn bộ, coverage Wave7 không còn "chỉ pure-function".

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp chung 1 sprint test-debt với [[P06-wave6-room-tag-test-mirrors-logic]] và [[P46-widget-tests-history-dashboard-screens]], làm cả 3 cùng lúc.
