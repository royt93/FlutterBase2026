# T121 — Idea: Ramp an toàn cục bộ theo tuổi install (D0/D3/D7/D30)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `lib/src/config/ad_config.dart`, `lib/src/utils/ad_preferences.dart` (đã có `firstInstallAtMs`)

## Vấn đề

T88 làm remote config qua host-supplied provider (cần network/Firebase). Bổ sung lựa chọn HOÀN TOÀN LOCAL: `AdConfig.safetyRampSchedule: Map<Duration, AdSafetyParams>` keyed theo thời gian-kể-từ-first-install — SDK tự áp `AdSafetyParams` tương ứng mốc mà không cần network call, cho app nhỏ không có backend vẫn ramp monetization theo D1/D7/D30.

## Việc cần làm

- [x] `AdConfig.safetyRampSchedule` optional, mặc định null = hành vi hiện tại không đổi
- [x] SDK tự chọn `AdSafetyParams` đúng mốc dựa trên `firstInstallAtMs`
- [x] Test: qua các mốc tuổi install khác nhau, xác nhận đúng params được áp; không set schedule → hành vi y hệt cũ

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/safety_ramp_schedule_test.dart` — xác nhận `AdConfig.safetyRampSchedule` type-check và không phá init thật. Đã ghi rõ trong test: đo chính xác stage-theo-tuổi-install cần fake `firstInstallAtMs` qua app restart thật, ngoài phạm vi 1 lần chạy — phần đó vẫn dựa vào unit test đã có. Đã viết, `flutter analyze` sạch, chưa chạy trên thiết bị.

**Xác nhận chạy thật trên thiết bị (2026-09-01):** pass trên emulator Pixel_10_Pro_XL và máy thật Samsung SM-S928B, `--dart-define=AD_PROVIDER_ADMOB=true`. Không phải chỉ `flutter analyze`.
