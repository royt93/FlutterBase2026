# T97 — Flagship: Client-side fill-rate/eCPM regression detector so baseline 7 ngày on-device

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng flagship, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart`, `packages/ad_sdk/lib/src/debug/` (compliance/debug overlay)

## Vì sao độc quyền
So sánh fill-rate/eCPM phiên hiện tại với baseline 7 ngày lưu cục bộ trên chính thiết bị, tự động cảnh báo "fill rate ad unit X giảm Y% so với baseline của thiết bị này" ngay trong debug/compliance overlay — điều dashboard AppLovin/AdMob thật cần backend để làm, ở đây chạy per-device, không cần server. Nhất quán hướng thiết kế offline-first xuyên suốt SDK (VIP Ed25519 offline, safety layer client-side).

## Việc cần làm (đề xuất, chưa code)
- [x] Lưu rolling 7-ngày fill-rate/eCPM per ad unit cục bộ.
- [x] So sánh phiên hiện tại vs baseline, threshold cảnh báo cấu hình được.
- [x] Hiển thị trong debug overlay (không cần thêm dependency backend).

## Đã làm (2026-08-16)

Ghi chú: `lib/src/debug/` (nêu trong Files) không tồn tại — debug overlay
thực tế nằm ở `lib/src/widget/debug_ad_overlay.dart`. Phát hiện thêm: overlay
hiện tại (kể cả trước ticket này) CHƯA từng hiển thị `FillRateMonitor`/
`AdDiagnostics` gì cả — nên phần "hiển thị debug overlay" ở đây là lần đầu
tiên bất kỳ dữ liệu monetization nào lên overlay, không chỉ riêng T97.

- `lib/src/utils/ad_preferences.dart` — `getFillRateBaselineHistory()`/
  `recordFillRateBaselineSample(...)`: 1 JSON blob keyed theo ngày ISO rồi
  `AdSlotType.name`, mỗi ô `{attempts, successes, revenueMicros, revenueCount}`,
  tự prune còn 7 ngày gần nhất mỗi lần đọc — cùng khuôn "1 blob, rollover lười"
  với `getPlacementDailyCounts` (T92).
- `lib/src/monetization/fill_rate_baseline_monitor.dart` (mới) —
  `FillRateBaselineMonitor`: nghe `AdManager().events`, mỗi `AdLoadEvent`/
  `AdRevenueEvent` vừa cộng vào tally phiên (in-memory, TOÀN BỘ vòng đời
  monitor — "phiên" nghĩa là cả session app, không phải rolling window ngắn)
  vừa persist vào bucket HÔM NAY. So `session` với baseline = tổng các ngày
  ĐÃ persist TRỪ hôm nay (loại trừ tự-so-với-chính-mình). Cảnh báo khi tụt
  ≥ `regressionThreshold` (mặc định 20%) so baseline, cần `minSamples` cả 2
  phía mới tin. `alerts` (stream, fire-once-per-regression) +
  `activeAlerts` (snapshot, dùng cho hiển thị one-shot).
  `FillRateRegressionAlert` mang cả 2 tín hiệu (fill rate VÀ avg-revenue-per-ad
  từ `AdRevenueEvent.valueMicros`) độc lập nhau.
- `lib/src/core/ad_manager.dart` — `enableFillRateBaselineMonitor({regressionThreshold, minSamples})`
  (async — cần `AdPreferences.getInstance()`, khác `enableFillRateMonitor`
  vốn host tự construct vì không cần quyền truy cập nội bộ),
  `disableFillRateBaselineMonitor()` (test seam), `fillRateBaselineMonitor`
  getter, dispose trong `destroy()`.
- `lib/src/monetization/ad_diagnostics.dart` — thêm field
  `fillRateRegressionBySlot` (nguồn từ `monitor.activeAlerts`), có trong
  `toJson()`.
- `lib/src/widget/debug_ad_overlay.dart` — `_FillRateRegressionRows` mới,
  render 1 dòng cam mỗi slot đang regressed (rỗng khi tắt/không có gì —
  không thêm dòng "no alert" placeholder).
- `lib/applovin_admob_sdk.dart` — export `fill_rate_baseline_monitor.dart`.
- Scope quyết định KHÔNG làm (tự quyết): không tính "eCPM" đúng nghĩa
  (revenue / 1000 impression) — dùng "average revenue micros per ad" làm
  proxy tương đương về mặt so sánh baseline-vs-session, tránh phải theo dõi
  thêm 1 bộ đếm impression riêng khi `AdLoadEvent.success` đã có sẵn cho fill
  rate; không thêm cấu hình threshold riêng cho từng `AdSlotType` (1
  `regressionThreshold`/`minSamples` chung, đơn giản đúng scope ticket).
- Test mới: `test/fill_rate_baseline_monitor_test.dart` (8 test, qua
  `AdManager().debugEmit(...)`, seed lịch sử ngày quá khứ thẳng vào
  SharedPreferences mock để không cần giả lập đồng hồ) — không cảnh báo khi
  chưa có baseline, không cảnh báo khi mẫu phiên chưa đủ `minSamples`, cảnh
  báo đúng khi tụt mạnh, không cảnh báo khi tụt trong ngưỡng, phát hiện
  revenue regression độc lập fill-rate, dữ liệu tự ghi hôm nay không bao giờ
  được dùng làm baseline của chính nó, stream fire-once rồi im khi vẫn còn
  regressed rồi fire lại sau khi hồi phục + tụt lại, mỗi `AdSlotType` theo
  dõi độc lập.
  Root-cause debug thật trong lúc viết test: `AdPreferences` là singleton
  cache tĩnh — gọi lại `SharedPreferences.setMockInitialValues({})` giữa các
  test KHÔNG tự làm mới `AdPreferences._instance` đã cache từ test trước, gây
  1 test ban đầu fail vì đọc nhầm state cũ; sửa bằng `AdPreferences.resetForTest()`
  trong `setUp` (convention đã có sẵn ở các test khác trong suite).
- `flutter analyze`: No issues found! `flutter test`: 825/825 pass.
