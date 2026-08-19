# Product Backlog — WiFi Stressor host app, audit vòng 2 (2026-08-11)

Nguồn: đọc lại toàn bộ `lib/mckimquyen/**` (2 subagent, đọc 100% file, chia scope: subagent 1 = core/common/const/controllers/services/models, subagent 2 = widgets/presentation/splash/main/vip/util/ext/formatter/translations/test) + 3 AI CLI độc lập audit cùng phạm vi song song: `codex exec`, `claude -p --dangerously-skip-permissions`, `agy --dangerously-skip-permissions`. `gemini --yolo` lỗi auth (free-tier Gemini Code Assist hết hỗ trợ, cần migrate Antigravity) — giống vòng 1, không có kết quả.

Mỗi source được yêu cầu 2 việc: (1) verify lại backlog vòng 1 (`BACKLOG-product-2026-08-10.md`, tickets `P01-P33`) trước, (2) chỉ báo cáo phát hiện **mới** hoặc **correction** — không lặp lại nguyên văn báo cáo cũ. Toàn bộ finding trong doc này đã được tôi (Claude, session điều phối) đọc code trực tiếp verify lại thêm 1 lần trước khi tạo ticket — các finding không verify được hoặc verify SAI bị loại, ghi rõ ở cuối doc để không mất công audit.

Item được ≥2 nguồn độc lập tìm thấy cùng vị trí đánh dấu **[đồng thuận]**.

---

## Corrections cho backlog vòng 1 (`P02-P33`)

| Ticket | Trạng thái mới | Lý do |
|---|---|---|
| [[P09-benchmark-screen-maxy-zero-divide]] | Chuyển `done/`, đóng | 3 nguồn (codex, claude CLI, subagent) xác nhận `benchmark_screen.dart:194,237` đã guard `maxY`/`horizontalInterval` từ trước khi ticket được ghi (2026-08-10). |
| [[P10-appsnackbar-doc-drift]] | Sửa bằng chứng | `test_detail_screen.dart` KHÔNG có raw `ScaffoldMessenger` (claim ban đầu của agy CLI sai) — 2 vị trí thật còn lại: `wifi_stressor_screen.dart:127,147`, `schedule_screen.dart:107`. |
| [[P11-force-null-cleanup]] | Sửa dòng | `stressor_controller.dart:469` là lời gọi hàm, `!` thật ở `:470`. |
| [[P13-wave7-test-coverage]] | Cập nhật | `test/wave7_server_selection_test.dart`, `test/wave7_data_limit_test.dart` đã tồn tại — bớt phần "server selector/data-limit chưa có test", vẫn thiếu integration cho `benchmark_screen`/`schedule_controller`/`room_comparison_screen`. |
| [[P21-comparison-screen-scale-limit]] | Sửa dòng + mở rộng | Header đã có `FittedBox` (`:216`), value rows thiếu fit ở `:268,310,340` (không phải `:247/288/325`). Thêm nghi vấn bảng màu chỉ 5 màu lặp lại khi ≥6 test (chưa verify kỹ). |

Các ticket sau được bổ sung bằng chứng mới (không đổi trạng thái, xem "Bổ sung (2026-08-11...)" trong từng file): [[P03-network-dashboard-getput-unguarded]], [[P04-csv-export-no-escape]], [[P05-history-date-range-boundary-exclusive]], [[P08-test-history-storage-double-init-guard]], [[P12-dead-code-cleanup]], [[P20-i18n-hardcoded-strings]], [[P24-retro-tag-room-history]], [[P30-exclusive-room-coverage-map]], [[P31-exclusive-isp-evidence-mode]].

---

## Epic A — Fix mới (`P34-P41`)

| # | Bug | Evidence | Sev |
|---|---|---|---|
| [[P34-location-permission-auto-open-settings]] | Từ chối quyền vị trí vĩnh viễn → app tự `openAppSettings()` không hỏi, lặp lại mỗi lần refresh dashboard/lưu test. | `network_info_service.dart:273-278,292`, gọi từ `stressor_controller.dart:585` | **P1** |
| [[P35-nested-materialapp-in-main]] | **[đồng thuận]** `MyApp` render `MaterialApp` con (theme `primarySwatch: Colors.red`) lồng trong `GetMaterialApp` gốc (theme thật `ColorConstants.appColor`). | `main.dart:75-121,149-170` | **P1** |
| [[P36-export-missing-roomtag-thermalstatus]] | **[đồng thuận]** CSV/PDF export thiếu cột `roomTag`/`thermalStatus` — JSON export có đủ, CSV/PDF thì không. | `history_controller.dart:483-519,422-449,693-715` | P2 |
| [[P37-upload-speed-ignores-http-status]] | `UploadSpeedService` set `validateStatus: (_) => true` và không đọc `statusCode` — captive portal/lỗi HTTP vẫn ra số Mbps giả. | `upload_speed_service.dart:19,30-34` | P2 |
| [[P38-schedule-rollback-asymmetry]] | Rollback khi `scheduleReminder()` lỗi không gọi `cancelReminder()` — không đối xứng với nhánh disable. | `schedule_controller.dart:118-127` | P2 |
| [[P39-history-controller-date-filter-exclusive]] | Tab Day/Week/Month dùng `isAfter(startDate)` exclusive — cùng lớp bug P05 nhưng ở file/hàm khác (UI filter, không phải storage export). | `history_controller.dart:129,131,135-143` | P3 |
| [[P40-export-temp-files-not-cleaned]] | File export tạm (CSV/PDF/JSON) không bị xoá sau khi `Share.shareXFiles`, tích lũy trong temp dir. | `history_controller.dart:378-392,579-605` | P3 |
| [[P41-test-detail-inforow-overflow]] | `_buildInfoRow` không có `Expanded`/ellipsis — SSID/roomTag/IP dài dễ overflow. | `test_detail_screen.dart:427-447` | P3 |

## Epic B — Enhance mới (`P42-P45`)

- [[P42-copywith-cannot-null-fields]] — `TestResult`/`NetworkInfo.copyWith` không thể set `roomTag`/`thermalStatus` về `null` (pattern `?? this.field`).
- [[P43-thermal-throttle-reduce-concurrency]] — tự giảm concurrency khi `thermalStatus` nghiêm trọng trong lúc đang test, không chỉ cảnh báo sau khi xong.
- [[P44-latency-service-fallback-endpoint]] — `LatencyService` chỉ có 1 host (Cloudflare), không có fallback khi bị chặn.
- [[P45-standardize-getx-binding]] — gốc rễ của cụm bug `Get.put` rải rác trong `build()` (P03 + tương tự) — đề xuất chuẩn hoá qua GetX `Binding`.

## Epic C — New task mới (`P46-P49`)

- [[P46-widget-tests-history-dashboard-screens]] — `history_screen.dart`/`network_dashboard_screen.dart` 0% widget test coverage.
- [[P47-export-filter-by-ssid-roomtag]] — lọc export theo SSID/room tag trước khi xuất.
- [[P48-export-offload-ui-thread]] — đo thử thời gian generate CSV/PDF với 100 item, quyết định có cần `compute()`/Isolate.
- [[P49-reschedule-notification-after-reboot]] — cần verify hành vi plugin notification sau reboot trước khi quyết định có cần code.

## Epic D — Idea mới (`P50-P55`)

- [[P50-idle-baseline-latency-probe]] — đo latency baseline lúc idle, hạ tầng trực tiếp cho `P25` bufferbloat score.
- [[P51-packet-loss-spike-alert]] — cảnh báo packet loss/latency-spike ngay trong lúc test, không chỉ xem sau khi xong.
- [[P52-router-vendor-advisory-table]] — bảng khuyến nghị theo vendor router (dùng OUI lookup đã có ở dashboard).
- [[P53-permission-denied-explainer-dialog]] — dialog giải thích trước khi xin quyền vị trí lần đầu (đi cùng P34).
- [[P54-wifi-roaming-handover-latency-tester]] — đo latency spike khi đổi BSSID (roaming giữa AP mesh).
- [[P55-background-packet-loss-alert]] — cảnh báo packet loss chạy nền qua WorkManager/BGTaskScheduler (cần research platform limit trước).

## Epic E — Exclusive mới (`P56`)

- [[P56-exclusive-thermal-aware-diagnostic]] — **[đồng thuận mạnh 3 nguồn]** ⭐ Thermal-Aware True-Speed Diagnostic / Fairness Index — nâng ý tưởng "thermal-aware speed testing" từ prose-only trong Epic E vòng 1 lên ticket cụ thể, do 3 nguồn độc lập (subagent, codex, agy) cùng đề xuất góc nhìn này ở vòng 2. Ghi chú liên quan đã thêm vào [[P30-exclusive-room-coverage-map]] (Signed Room Walk Certificate, Router Placement Experiment Mode) và [[P31-exclusive-isp-evidence-mode]] (loại trừ thermal khi tính % dưới cam kết + QR verify) — không tách ticket riêng cho 2 ý đó vì chúng là enrichment của feature đã có, không phải hướng mới độc lập.

---

## Finding của agy CLI đã verify và BÁC BỎ (ghi lại để không audit lại lần sau)

agy CLI trong vòng này có tỷ lệ false-positive cao hơn các nguồn khác (có thể do hành vi tự lặp lại báo cáo 2 lần trong 1 lần chạy). 3 claim sau đã đọc code trực tiếp và xác nhận SAI, không tạo ticket:
- ~~`HistoryController.onInit()` không có try/catch quanh `_loadHistory()`~~ — sai, `_initializeStorage()` (`:73-86`) và `loadHistory()` (`:89+`) đều có try/catch/finally đầy đủ.
- ~~`LatencyService.dnsLookup()` không bắt được `TimeoutException`~~ — sai, `catch (e)` ở `:52` bắt mọi exception kể cả timeout.
- ~~`RoomComparisonScreen` chia 0/`StateError` khi list rỗng~~ — sai, đã guard `tagged.isEmpty` trước khi group theo phòng (`room_comparison_screen.dart:30-50`), mỗi phòng trong `byRoom` luôn có ≥1 item nên `reduce()` sau đó an toàn.

---

## Ghi chú khác

- Tổng số ticket mới vòng này: 23 (`P34-P56`). Cùng với `P01-P33` từ vòng 1, track Product hiện có 56 ticket (1 done, còn lại todo).
- `comparison_screen.dart` reduce() trên giá trị "best"/"worst" khi có test bị interrupted (`isSuccessful == false`, speed = 0/null) — agy CLI có nêu nhưng tôi chưa verify kỹ do giới hạn thời gian audit vòng này; đã ghi làm gợi ý "cần verify thêm" trong [[P21-comparison-screen-scale-limit]], không tạo ticket riêng để tránh false-positive giống 3 case trên.
- `NetworkDashboardController` có khả năng race khi dispose giữa lúc các `Future` song song (public IP/network info) còn đang chạy — plausible nhưng chưa tự verify, đã ghi làm note liên quan trong [[P03-network-dashboard-getput-unguarded]] thay vì tạo ticket riêng.
