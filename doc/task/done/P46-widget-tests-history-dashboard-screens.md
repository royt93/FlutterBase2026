# P46 — Viết widget test cho `history_screen.dart` và `network_dashboard_screen.dart` (0% coverage)

- **Priority:** P2 · **Severity:** — · **Status:** ✅ done (2026-08-12)
- **Nguồn:** claude CLI (audit độc lập)
- **Files:** `presentation/history_screen.dart`, `presentation/network_dashboard_screen.dart`, `test/`

## Vấn đề
2 screen này chưa có widget test nào trong `test/` (khác với các screen khác đã có wave-test tương ứng, xem `doc/task/README.md` cho danh sách wave hiện có) — regression về filter tab, export flow, hoặc render dashboard sẽ không bị bắt bởi CI.

## Việc cần làm (đề xuất, chưa code)
- `wave8_history_screen_test.dart` (hoặc số wave tiếp theo): render, đổi tab Day/Week/Month, verify list lọc đúng (đối chiếu [[P39-history-controller-date-filter-exclusive]] sau khi fix).
- `wave8_network_dashboard_screen_test.dart`: render, verify hiển thị SSID/public IP/gateway (mock service), verify guard `Get.put` sau khi fix P03.

## Acceptance criteria
- [x] Cả 2 screen có ít nhất 1 test render + 1 test tương tác qua code thật (không mirror logic).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp chung 1 sprint test-debt với [[P06-wave6-room-tag-test-mirrors-logic]] và [[P13-wave7-test-coverage]], làm cả 3 cùng lúc.

## Kết quả (2026-08-12)

**`test/wave8_history_screen_test.dart`** (mới, 2 test) — mock `path_provider`
(pattern P13, `test/fake_path_provider.dart`) để `TestHistoryStorage` mở box
Hive thật. Test render empty-state, và render 4 kết quả thật (fixture theo
`DateTime.now()` thật, vì `HistoryController._applyTimeRangeFilter`/
`_formatDateKey` dùng wall-clock thật, không fake-async) rồi tap từng tab
Day/Week/Month, verify qua `HistoryController` thật là item ngoài range biến
mất. Text "X.X Mbps" bị trùng giữa `TimelineItem` và `SummaryStatsCard`
(fixture 10/20/30/40 trùng với peak/avg tính toán) — fix bằng
`find.descendant(of: find.byType(TimelineItem), matching: find.text(...))`.

**`test/wave8_network_dashboard_screen_test.dart`** (mới, 1 test) — không mock
`NetworkInfoService`: mọi plugin channel (connectivity_plus, network_info_plus,
permission_handler, native wifi channel) không có handler trong `flutter test`
→ `MissingPluginException`, nhưng service đã try/catch fallback về null/rỗng ở
mọi method — đây là hành vi thật (giống cách P13 test `ScheduleController`
permission-denied là hành vi thật, không mock). `getPublicIp()` gọi Dio ra
network thật, nhưng `flutter_test` tự chặn `HttpClient` (mọi request trả về
400) nên không có network call thật nào xảy ra và test chạy nhanh (~5s). Verify
render "N/A" fallback đúng qua code thật + tap refresh icon gọi lại
`NetworkDashboardController.refreshData()` thật không crash. `net_dns`.tr
trùng cả tên card lẫn label dòng "no DNS" khi rỗng → dùng `findsWidgets` thay
vì `findsOneWidget`.

Xác nhận: `flutter analyze` sạch, `flutter test` 175/175 pass.
