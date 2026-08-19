# Product Backlog — WiFi Stressor host app (2026-08-10)

Nguồn: đọc toàn bộ `lib/mckimquyen/**` qua 2 subagent (đọc 100% file, không excerpt) + 3 AI CLI độc lập audit cùng phạm vi song song: `codex exec`, `claude --dangerously-skip-permissions` (session riêng, không phải session này), `agy --dangerously-skip-permissions`. `gemini` CLI lỗi auth (tài khoản free-tier hết hỗ trợ Gemini Code Assist, cần migrate Antigravity) — không có kết quả. Không đụng `packages/ad_sdk/**` (đã audit 12+ vòng, 10/10, xem `doc/audit/`).

Item được ≥2 nguồn độc lập tìm thấy cùng vị trí được đánh dấu **[đồng thuận]** — độ tin cậy cao hơn.

Quy ước ID mới: **Pxx** (Product), tách khỏi `Txx` (dành riêng cho SDK, xem `doc/task/README.md`). Chưa tạo file `Pxx` riêng — đây là backlog để chọn trước khi rã thành ticket trong `doc/task/todo/`.

---

## Epic A — Fix (bug thật, có bằng chứng file:line)

| # | Bug | Evidence | Sev |
|---|---|---|---|
| A1 | **Zombie download loop sau dispose** — `StressorController.onClose()` (`stressor_controller.dart:242-273`) lưu kết quả rồi defer `_cleanup()` 100ms nhưng không set `isRunning.value = false`. `_runDownloadLoop`'s `while(isRunning.value)` (`:798`) chạy tiếp vô hạn; `dio` đã đóng ở `_cleanup()` (`:286`) nên mỗi `dio.get()` throw, catch, retry mỗi 100ms mãi. | `stressor_controller.dart:242-273,798,286` | **P0 — leak thật** |
| A2 | **`AnimatedNumberText`/`AnimatedIntText` không animate** — `Tween(begin: value, end: value)`, begin=end mỗi rebuild nên giá trị nhảy tức thì, không interpolate. So sánh đúng ở `speedometer_gauge_widget.dart:50` (không set `begin`). Ảnh hưởng hiển thị `average_speed`/`data_downloaded`. | `widgets/animated_number_text.dart:23,54` | P1 — UI bug |
| A3 | **`Get.put` gọi không điều kiện trong `build()`** ở `network_dashboard_screen.dart:17`, khác mọi màn hình khác đều guard bằng `Get.isRegistered<...>()`. Parent rebuild → tạo lại controller → `onInit()`→`refreshData()` chạy lại → loading spinner nhấp lại. | `network_dashboard_screen.dart:17` | P1 |
| A4 | **CSV export không escape field** — `history_controller.dart:499-519` viết CSV thẳng không escape; SSID/room tag chứa dấu phẩy/newline sẽ vỡ định dạng export. | `history_controller.dart:499-519` | P1 — data corruption |
| A5 | **[đồng thuận — codex + subagent]** Khoảng ngày export/history dùng `isAfter`/`isBefore` (exclusive), loại bỏ test đúng ranh giới đầu/cuối ngày khỏi báo cáo ISP dispute. | `test_history_storage.dart:162-164` | P2 |
| A6 | **[đồng thuận — claude CLI + subagent]** `wave6_room_tag_test.dart` tự viết lại logic group/aggregate room thay vì import `RoomComparisonScreen` thật → màn hình thật **zero test coverage**, bug thật có thể lọt CI mà test vẫn xanh. | `test/wave6_room_tag_test.dart` | P1 — false test coverage |
| A7 | `TestDetailScreen` gọi `Get.find<HistoryController>()` khi xoá kết quả — nếu screen mở trực tiếp (không qua History) mà controller chưa register → crash. | `test_detail_screen.dart:598` | P2 |
| A8 | Chưa có guard chống double-init `TestHistoryStorage.init()` (khác `BenchmarkSettingsStorage`/`ScheduleStorage` đã có) — 3 controller gọi `init()` độc lập lúc khởi động, có thể mở Hive box 2 lần cùng lúc. | `services/test_history_storage.dart:36-78` | P2 |
| A9 | `benchmark_screen.dart` — `maxY = ceiling * 1.2`; nếu chưa cấu hình advertised speed và mọi tốc độ đo = 0.0 → `maxY = 0.0` → chia 0 ở `horizontalInterval` → `NaN`. | `benchmark_screen.dart:170,194` | P2 |
| A10 | **[đồng thuận toàn bộ 5 nguồn]** `AppSnackbar` được CLAUDE.md và `doc/init.md` nhắc tới **không tồn tại trong code** (verify: `grep -rn "class AppSnackbar" lib/` → rỗng). Pattern thật là `UIUtils.showToast` (`util/ui_utils.dart:907`). Đồng thời `wifi_stressor_screen.dart:127,147`, `schedule_screen.dart:107` dùng raw `ScaffoldMessenger.showSnackBar` — không theo cả 2 pattern trên. | doc drift + `wifi_stressor_screen.dart:127,147`, `schedule_screen.dart:107` | **P0 — doc sai + code không nhất quán** |
| A11 | Force-null `!` rải rác vẫn còn (đều có guard, không crash thật nhưng vi phạm quy ước "no `!`" trong `doc/init.md`): `splash_screen.dart:200,367,401,418`, `stressor_controller.dart:469`, `test_detail_screen.dart:300`, `room_comparison_screen.dart:49`, `heatmap_screen.dart:27,30`, `util/exit_app.dart:13`, `main.dart:101`. | nhiều file | P3 — cleanup |
| A12 | Dead code đáng kể (0 caller trong toàn `lib/`, đã grep xác nhận): `MainScreen` (không route nào tới còn active), `showAlertDialogWidget`/`showAlertDialog` (`base_stateful_state.dart`), `AppLoading` (`base_controller.dart`), `HeroConstants`/`Constants`, `ExitApp.handlePop` (chưa wire vào `PopScope` nào), và ~20 method trong `UIUtils`/`UrlLauncherUtils`. | nhiều file, xem chi tiết trong report subagent | P3 — dọn dẹp |

## Epic B — Enhance

- **[đồng thuận — claude CLI + subagent]** Wave7 (`benchmark_screen`, `schedule_controller`, `schedule_storage`, `benchmark_settings_storage`, `room_comparison_screen`) — logic thật, không trivial, **chỉ test được các pure-function con** (`pctOfAdvertised`, `nextFireTime`...), controller wiring + persistence + rendering chưa ai verify. Đây là track đang "in progress" theo `doc/feature.md`.
- **[đồng thuận — claude CLI + subagent]** `network_dashboard_controller.dart` không đọc `totalBytesIncludingProgress` (đã có sẵn ở `stressor_controller.dart:57`) — dashboard không show được tổng data đã tiêu tốn qua các lần test.
- **[đồng thuận — codex + agy]** Heatmap chỉ normalize theo global max, luôn 24-cell bất kể thời gian test thật — phòng yếu sóng bị "chìm" khi so với phòng khác quá mạnh.
- `schedule_screen.dart` hiện chỉ là nhắc nhở (tự confirm bằng disclaimer trong chính screen) — không tự chạy test nền, cần user mở app thủ công.
- Hardcode tiếng Anh chưa qua `.tr` ở nhiều nơi độc lập nhau: `_shareResult()` (`test_detail_screen.dart:516-579`), `control_button_widget.dart:67` (ad disclosure), splash title `'FastNet\nSpeed Test'` (`splash_screen.dart:457` — trong khi key `app_title` đã tồn tại sẵn).
- `comparison_screen.dart` không giới hạn số test so sánh, cột metric không có `FittedBox`/ellipsis → vỡ layout khi so nhiều test.
- Logic format ngày giờ và ngưỡng dBm bị copy-paste 2 nơi (`test_detail_screen.dart` vs `summary_stats_card.dart`; `network_dashboard.dart` vs `test_result.dart`) thay vì dùng chung `formatter/`.

## Epic C — New task (nối tiếp cái đã có, không phải ý tưởng mới)

- **[đồng thuận 3 nguồn: codex + agy + subagent]** Heatmap drill-down: tap 1 cell → mở `TestDetailScreen` đúng thời điểm đó.
- **[đồng thuận: codex + claude CLI + subagent]** Ghép `room_comparison_screen` (đã có `roomTag`) với `heatmap_screen` thành lưới phòng × thời gian, thay vì 2 màn tách biệt.
- Nối `totalBytesIncludingProgress` vào `network_dashboard_screen.dart` (field đã có sẵn, chỉ cần đọc).
- Viết test thật cho cụm Wave7 (`wave7_benchmark_screen_test.dart`, `wave7_schedule_controller_test.dart`...) + sửa `wave6_room_tag_test.dart` import `RoomComparisonScreen` thật (fix A6).
- Lưu lựa chọn multi-server (Wave 7) qua restart app — hiện mất khi tắt app (`stressor_controller.dart:143`).
- Cho phép gắn/sửa `roomTag` cho các test cũ trong history (hiện chỉ gắn được lúc test mới).
- Schedule: thêm nhiều preset đặt tên (VD "Test đêm 2h", "Test giờ nghỉ trưa") thay vì 1 slot.

## Epic D — Idea (mới, chưa có hạ tầng sẵn 100%)

- **[đồng thuận mạnh 3 nguồn: codex + agy + claude CLI]** **Bufferbloat score** — so latency lúc idle vs lúc đang tải nặng (đo được ngay trong 1 lần stress test).
- **[đồng thuận: codex + agy]** Phân biệt "mạng chậm do ISP" vs "máy nóng làm chậm" dùng field `thermalStatus` đã có sẵn.
- Tự động cảnh báo khi kết quả tụt dưới X% so với benchmark cá nhân (`pctOfAdvertised` đã có, thiếu bước trigger notification).
- Tự chạy test khi phát hiện đổi SSID (qua `NetworkInfoService`) để so sánh nhà/công ty/quán cà phê.
- Phân tích pattern nghẽn theo khung giờ từ lịch sử heatmap đã lưu sẵn trong Hive (không cần thêm hạ tầng đo, chỉ cần thêm phân tích).

## Epic E — Exclusive/differentiating feature (khác Speedtest.net/Fast.com)

- **[đồng thuận mạnh 3 nguồn: codex + agy + claude CLI]** ⭐ **Bản đồ vùng sóng yếu theo phòng (Room Coverage / Dead-Zone Map)** — biến `roomTag` + heatmap + Hive history có sẵn thành flow "đi từng phòng, bấm test" → xếp hạng phòng yếu nhất, gợi ý đặt lại router/mesh. Không đối thủ nào có tính năng này.
- **[đồng thuận: codex + claude CLI]** **ISP Dispute Evidence Mode nâng cấp** — `exportIspDisputeReport()` đã có (`history_controller.dart:533`), nâng thành báo cáo đa tuần có thể ký số (tận dụng sẵn hạ tầng Ed25519 verify của VIP key) làm bằng chứng khiếu nại ISP đáng tin hơn.
- **[đồng thuận: codex + agy]** **Multi-CDN fairness score** — so song song Cloudflare/Fast.com/GitHub/Linode/Vultr để phân biệt ISP nghẽn backhaul vs 1 CDN đang bị throttle riêng.
- **VIP network health monitor chạy nền dài hạn** — nâng `schedule_controller`/`notification_service` đã có sẵn thành tính năng VIP: tự test định kỳ, biểu đồ xu hướng tuần/tháng — đối thủ chỉ test 1 lần rồi thôi, không app nào giữ lịch sử dài hạn kèm phân tích.
- **Thermal-aware speed testing** làm feature độc lập, không chỉ là idea nhỏ — dùng `thermalStatus` đã lưu sẵn trong `TestResult` để tách "mạng chậm" khỏi "máy nóng".

---

## Ghi chú khác (không phải backlog, nhưng đáng sửa nhanh)

- CLAUDE.md + `doc/init.md` đang trỏ tới component `AppSnackbar` không tồn tại (xem A10) — nên sửa doc để khớp `UIUtils.showToast`, hoặc đổi tên `showToast`→`AppSnackbar` cho khớp doc. Cần quyết định hướng nào.
- 2 file translation `en_us.dart`/`vi_vn.dart` đủ 250 key khớp nhau, không thiếu key nào — sạch, không cần task.
