# P27 — Idea: cảnh báo tự động khi tốc độ tụt dưới % benchmark cá nhân

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/benchmark_controller.dart` (đã có `pctOfAdvertised`/`isAboveAdvertised`)

## Ý tưởng
`BenchmarkController` đã tính sẵn `pctOfAdvertised`/`isAboveAdvertised` — chỉ thiếu bước trigger notification khi kết quả tụt dưới ngưỡng X% so với gói cước quảng cáo.

## Việc cần làm (đề xuất, chưa code)
- Sau khi lưu test result, check `pctOfAdvertised` — nếu dưới ngưỡng (config được, default gợi ý 50-70%), bắn local notification qua `NotificationService` đã có sẵn.
- Cân nhắc rate-limit cảnh báo (không spam mỗi lần test đều tụt).

## Acceptance criteria
- [x] Test tụt dưới ngưỡng → có notification, không spam nếu tụt liên tục nhiều lần trong thời gian ngắn.
- [x] Ngưỡng cảnh báo config được trong benchmark settings.

## Kết quả (2026-08-13)
- `services/benchmark_drop_alert.dart`: pure function `shouldFireBenchmarkDropAlert(...)`, tái dùng `BenchmarkController.pctOfAdvertised()` thay vì tính lại % — chỉ thêm ngưỡng (`kDefaultDropAlertThresholdPercent = 60.0`) + cooldown rate-limit (`kDropAlertCooldown = Duration(hours: 6)`) chống spam khi nhiều test liên tiếp đều tụt.
- `BenchmarkSettingsStorage` mở rộng thêm `alertThresholdPercent`/`setAlertThresholdPercent` (config được, persist Hive) và `lastDropAlertAt`/`setLastDropAlertAt` (rate-limit state) — cùng pattern getter/setter với `advertisedSpeedMbps` sẵn có.
- `NotificationService.showBenchmarkDropAlert(...)` bắn notification tức thời qua `_plugin.show(...)` (kênh mới `benchmark_drop_alert_channel`, ID `9500` — nằm ngoài dải 9002-9098 mà schedule reminder chiếm) — trước đây service chỉ có `scheduleReminder` (tương lai), chưa có đường bắn ngay.
- `stressor_controller.dart._saveTestResult()`: thêm `unawaited(_maybeFireBenchmarkDropAlert(result))` ngay sau log "✅ Test result saved", guard bởi `result.isSuccessful`, không throw ra ngoài (try/catch riêng) để không ảnh hưởng luồng lưu test chính.
- `presentation/benchmark_screen.dart`: thêm hàng cấu hình ngưỡng % (icon-button mở dialog nhập số, tái dùng pattern dialog của `_promptAdvertisedSpeed`) — thoả AC2.
- Test mới: `test/p27_benchmark_drop_alert_test.dart` (5 case: fire khi tụt, không fire khi đạt ngưỡng, không fire khi chưa cấu hình tốc độ quảng cáo, không spam trong cooldown, fire lại sau khi hết cooldown).
- `ponytail:` không thêm channel importance tuỳ biến theo mức độ tụt (chỉ 1 mức `Importance.high` cố định) — ticket không yêu cầu phân cấp mức độ cảnh báo.
