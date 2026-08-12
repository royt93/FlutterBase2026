# P06 — `wave6_room_tag_test.dart` test logic giả lập, không test màn hình thật

- **Priority:** P1 · **Severity:** HIGH · **Status:** ✅ done (2026-08-12)
- **Nguồn:** claude CLI (audit độc lập), tinh thần trùng với "zero widget-test coverage" của subagent đọc source
- **Files:** `test/wave6_room_tag_test.dart`, `lib/mckimquyen/widget/wifi_stressor/presentation/room_comparison_screen.dart`

## Vấn đề
`wave6_room_tag_test.dart` tự viết lại logic group/aggregate theo room (comment trong file ghi rõ "mirrors RoomComparisonScreen math") thay vì import và test trực tiếp `RoomComparisonScreen`. Hệ quả: **màn hình thật không có test nào chạy qua nó** — nếu logic thật trong screen có bug (hoặc bị sửa sai sau này), test vẫn xanh vì nó chỉ test bản copy độc lập. Đây là kiểu "drift giữa 2 bản logic", nguy hiểm hơn thiếu test thông thường vì tạo cảm giác an toàn giả.

## Bằng chứng
- `test/wave6_room_tag_test.dart` (toàn file — comment tự nhận "mirrors" logic thật).
- `room_comparison_screen.dart:32` — logic group/aggregate thật, không được test nào gọi tới.

## Việc cần làm (đề xuất, chưa code)
- Viết lại test import trực tiếp `RoomComparisonScreen`/`RoomComparisonController` (nếu có) thay vì mirror logic, dùng widget test hoặc unit test gọi thẳng hàm group/aggregate thật.
- Giữ lại test case hiện có (đủ coverage case), chỉ đổi target test sang code thật.

## Acceptance criteria
- [x] Test mới gọi trực tiếp vào code path thật của `RoomComparisonScreen`, không viết lại logic song song.
- [x] Cố tình inject 1 bug giả vào `room_comparison_screen.dart` lúc dev để confirm test mới catch được (rồi revert) — sanity check test thật sự "ăn" vào code thật.

## Kết quả (2026-08-12)
Test mới `test/p06_room_comparison_screen_test.dart` pump chính `RoomComparisonScreen` (không mirror logic): populate `HistoryController.allResults` trực tiếp rồi assert text render ra màn hình — thứ tự phòng theo avg giảm dần, giá trị avg/peak/min mỗi phòng, note "@count failed test(s)..." cho phòng có tagged-failed, phòng toàn-failed vẫn hiện (không có metric row), test chưa tag bị loại hoàn toàn, và số lượng test/phòng (`room_comparison_tests`).
Sanity check: đổi tạm dòng sort `..sort((a, b) => _avgOf(b.value).compareTo(_avgOf(a.value)))` thành chiều ngược (`a`↔`b`) → test mới fail đúng vào assertion thứ tự phòng (`Expected: [Kitchen, Bedroom, Garage], Actual: [Garage, Bedroom, Kitchen]`), xác nhận test ăn vào code thật, không phải bản mirror. Đã revert lại nguyên bản.
Giữ `wave6_room_tag_test.dart` (không xoá — vẫn hữu ích cho boundary case của Hive adapter, không liên quan RoomComparisonScreen).
`flutter analyze` sạch, `flutter test` 164/164 pass.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp chung 1 sprint test-debt với [[P13-wave7-test-coverage]] và [[P46-widget-tests-history-dashboard-screens]], làm cả 3 — không merge code (3 file/screen độc lập), chỉ gộp lịch/sprint vì cùng loại việc (viết test thật thay test giả lập/thiếu test).
