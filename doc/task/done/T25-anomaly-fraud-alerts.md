# T25 — Anomaly/fraud alert stream

- **REQ:** 7 (policy tuân thủ) + epic "Trust & Analytics"
- **Priority:** P2 · **Severity:** — (feature mới) · **Status:** done
- **Nguồn:** quyết định user 2026-07-08
- **Phụ thuộc:** dùng `AdEvent` sealed class (đã có, `ad_event.dart`) — làm song song hoặc sau T23, không phụ thuộc cứng.
- **Files dự kiến:** `packages/ad_sdk/lib/src/state/ad_event.dart` (thêm `AdAnomalyEvent`), `packages/ad_sdk/lib/src/core/ad_safety_config.dart` (`_triggerSuspiciousPause` phát thêm event thay vì chỉ log nội bộ)

## Vấn đề (Why)

`AdSafetyConfig._triggerSuspiciousPause()` (`ad_safety_config.dart`) đã phát hiện đúng 2 loại bất thường (CTR anomaly, click spam) nhưng chỉ `SafeLogger.w` nội bộ + tự pause — **không có tín hiệu nào lọt ra ngoài** qua `AdManager().events`. Partner không có cách nào biết "SDK vừa tự chặn 1 khả năng gian lận" trừ khi tự đọc log debug — không thể tích hợp vào Firebase/Sentry/dashboard riêng như các `AdEvent` khác đã hỗ trợ.

## Fix đề xuất

1. Thêm `AdAnomalyEvent extends AdEvent` (`ad_event.dart`) với field `reason` (String, tái dùng message đã có sẵn trong `_triggerSuspiciousPause`), `violationCount`, `pauseDurationMs`. Giữ đúng pattern sealed class hiện tại — không đổi các subtype khác.
2. `_triggerSuspiciousPause()` nhận thêm 1 callback/sink để emit `AdAnomalyEvent` qua `AdManager().events` — cách nối rẻ nhất là `AdSafetyConfig` giữ 1 `void Function(AdAnomalyEvent)?` set từ `AdManager` lúc init (tương tự cách `_prefs` được set), tránh việc `AdSafetyConfig` phải import `AdManager` ngược (vòng phụ thuộc).
3. Không tự thêm anomaly type mới ngoài 2 loại đã detect (CTR, click spam) — anomaly eCPM/invalid-traffic từ nguồn ngoài (mạng quảng cáo, click farm bên thứ 3) cần baseline thống kê dài hạn, out of scope version đầu (ghi rõ trong doc, tránh over-promise).

## Acceptance criteria
- [x] `AdAnomalyEvent` mới, không đổi các `AdEvent` subtype khác.
- [x] Mọi lần `_triggerSuspiciousPause()` chạy đều emit đúng 1 `AdAnomalyEvent` qua stream (test bằng cách listen `AdManager().events` và giả lập CTR vượt ngưỡng).
- [x] Vẫn emit event kể cả khi `AdSafetyParams.dryRun == true` — dry-run chỉ bypass block, không bypass tín hiệu anomaly (rõ trong code comment ở `_triggerSuspiciousPause`).
- [x] Test mới verify event payload đúng (reason, violationCount tăng dần đúng theo progressive cooldown).
- [x] `flutter analyze` sạch, test SDK xanh.

## Kết quả
- `AdAnomalyEvent` + sink injection (`AdSafetyConfig.setAnomalySink`, wired từ `AdManager.initialize()`).
- Unit test: `packages/ad_sdk/test/ad_anomaly_event_test.dart` (5/5 pass — no-sink, CTR anomaly, progressive-cooldown doubling, click spam, dry-run).
- Demo UI: `EventsDemoPage` render `AdAnomalyEvent` với badge "ANOMALY" + reason/violation/pause duration.
- Widget test: `packages/ad_sdk/example/test/events_demo_anomaly_test.dart`.
- Integration test: `packages/ad_sdk/example/integration_test/anomaly_event_test.dart` — pass trên Pixel 7 Pro (`2B051FDH3006MU`).
- `flutter analyze` sạch cả `packages/ad_sdk` và `packages/ad_sdk/example`; `flutter test` xanh toàn bộ 2 package.
