# T122 — Idea: Waterfall tuner on-device theo placement

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (batch D, 2026-08-31)
- **Files:** `state/ad_event.dart`, compliance log, fill-rate monitors, diagnostics, experiment bucket

## Vấn đề

Event hiện có load latency, fill/revenue/network name nhưng chưa biến chúng thành khuyến nghị cấu hình. [đồng thuận 3 nguồn, effort XL]

## Việc cần làm

- [x] Lưu rolling score theo provider/format/placement (fill, eCPM — KHÔNG latency, xem "Đã làm")
- [x] Đưa ra khuyến nghị local "ưu tiên provider X cho placement Y" — `WaterfallTuner.recommendation()`
- [x] Không auto-switch (không có tự động gì cả) — chỉ trả recommendation, host tự quyết cho `initialize()` phiên sau. KHÔNG load shadow ad — chỉ đọc `AdManager().events` đã có
- [x] Test: `test/waterfall_tuner_test.dart` (4 test) — rolling score đúng, khuyến nghị đúng hướng, không khuyến nghị khi thiếu mẫu/current đã tốt hơn, dispose() dừng nghe

## Đã làm (batch D, 2026-08-31)

`lib/src/monetization/waterfall_tuner.dart` — mirror đúng pattern
`FillRateMonitor` đã có (opt-in qua `AdManager().enableWaterfallTuner(...)`,
tự dispose trong `destroy()`/`_resetGuardState()`). **Bỏ latency khỏi score**
— `AdLoadEvent` không có timestamp delta, không có tín hiệu latency thật để
tính; thêm 1 field giả sẽ tệ hơn không thêm. Score = fillRate × avg eCPM
(micros), cần tối thiểu `minSampleSize = 6` lần thử gộp cả 2 provider trước
khi khuyến nghị bất cứ gì.

## Ghi chú

Làm sớm, độc lập với FLAGSHIP-A/T127 theo quyết định user — nhưng cân nhắc thiết kế rolling-score chung nếu 2 việc chạy song song để tránh trùng lặp code đo lường fill-rate/latency.

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/waterfall_tuner_test.dart` — `enableWaterfallTuner` thật, subscribe event stream thật, gọi `recommendation()`. Đã viết, `flutter analyze` sạch, chưa chạy trên thiết bị.

**Xác nhận chạy thật trên thiết bị (2026-09-01):** pass trên emulator Pixel_10_Pro_XL và máy thật Samsung SM-S928B, `--dart-define=AD_PROVIDER_ADMOB=true`. Không phải chỉ `flutter analyze`.
