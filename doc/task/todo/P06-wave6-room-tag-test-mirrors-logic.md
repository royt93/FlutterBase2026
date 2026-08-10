# P06 — `wave6_room_tag_test.dart` test logic giả lập, không test màn hình thật

- **Priority:** P1 · **Severity:** HIGH · **Status:** 🔲 todo
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
- [ ] Test mới gọi trực tiếp vào code path thật của `RoomComparisonScreen`, không viết lại logic song song.
- [ ] Cố tình inject 1 bug giả vào `room_comparison_screen.dart` lúc dev để confirm test mới catch được (rồi revert) — sanity check test thật sự "ăn" vào code thật.
