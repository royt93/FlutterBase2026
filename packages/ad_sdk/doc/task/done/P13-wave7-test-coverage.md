# P13 — Viết test thật cho cụm Wave 7 (đang 0 coverage cho phần integration)

- **Priority:** P1 · **Severity:** HIGH · **Status:** ✅ done (2026-08-12)
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
- [x] Mỗi file/controller kể trên có ít nhất 1 test chạy qua code thật (không mirror logic).
- [x] `flutter test` xanh toàn bộ, coverage Wave7 không còn "chỉ pure-function".

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp chung 1 sprint test-debt với [[P06-wave6-room-tag-test-mirrors-logic]] và [[P46-widget-tests-history-dashboard-screens]], làm cả 3 cùng lúc.

## Kết quả (2026-08-12)

**`test/fake_path_provider.dart`** (mới, shared helper) — mock channel
`plugins.flutter.io/path_provider` trả về temp dir thật, để
`Hive.initFlutter()` mở box thật trong `flutter test` (test host không có
native path_provider). Dùng chung cho cả 2 file test bên dưới.

**`test/wave7_schedule_controller_test.dart`** (mới, 4 test) — test thật
`ScheduleController` + `ScheduleStorage` qua Hive box thật:
- `setEnabled(true)` bị chặn bởi permission denied (test host không phải
  Android/iOS thật) — hành vi thật, không mock permission.
- `setTime`/`toggleWeekday` ghi đúng xuống Hive box thật.
- Xoá weekday cuối cùng tự ép `enabled=false`.

Blocker gặp phải: `FlutterLocalNotificationsPlatform.instance` là
`static late`, chỉ được set bởi plugin thật lúc app khởi động trên device —
`ScheduleController` gọi `NotificationService.cancelReminder()`/
`scheduleReminder()` trên MỌI code path đều đọc `.instance`, không cách nào
né. Fix: gọi `AndroidFlutterLocalNotificationsPlugin.registerWith()` 1 lần
trong `setUpAll` (set `.instance` thật) + mock no-op channel
`dexterous.com/flutter/local_notifications`.

**`test/wave7_benchmark_screen_test.dart`** (mới, 3 test) — test thật
`BenchmarkController` + `BenchmarkSettingsStorage` qua Hive box thật
(`setAdvertisedSpeed`/clear), + 1 widget test verify `BenchmarkScreen` render
đúng "no baseline" hint rồi cập nhật đúng sau khi controller thật đổi giá
trị. Bỏ hẳn cách lái UI qua `Set → nhập số → OK` (`Get.dialog`): animation
đóng dialog + dispose `TextEditingController` đua với real-time trong
`flutter test` ra lỗi ngẫu nhiên "Tried to build dirty widget in the wrong
build scope" — test trực tiếp controller ổn định hơn nhiều mà vẫn chạy qua
code thật (không mirror logic).

**`test/wave7_data_limit_test.dart`** (bổ sung 1 test) — tap chip "Custom"
(disambiguate với chip "Custom" của duration selector bằng `.at(1)`, do
`_buildDurationSelector` build trước `_buildDataLimitSelector`) → nhập MB
→ tap OK → verify `StressorController.dataLimitMb` cập nhật đúng qua
`_CustomDataLimitDialog` thật.

`room_comparison_screen.dart` đã có test thật từ P06
(`test/p06_room_comparison_screen_test.dart`), không cần làm lại.

Xác nhận: `flutter analyze` sạch, `flutter test` 172/172 pass.
