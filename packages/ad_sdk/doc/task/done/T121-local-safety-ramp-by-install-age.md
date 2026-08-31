# T121 — Idea: Ramp an toàn cục bộ theo tuổi install (D0/D3/D7/D30)

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/config/ad_config.dart`, `lib/src/utils/ad_preferences.dart` (đã có `firstInstallAtMs`)

## Vấn đề

T88 làm remote config qua host-supplied provider (cần network/Firebase). Bổ sung lựa chọn HOÀN TOÀN LOCAL: `AdConfig.safetyRampSchedule: Map<Duration, AdSafetyParams>` keyed theo thời gian-kể-từ-first-install — SDK tự áp `AdSafetyParams` tương ứng mốc mà không cần network call, cho app nhỏ không có backend vẫn ramp monetization theo D1/D7/D30.

## Việc cần làm

- [ ] `AdConfig.safetyRampSchedule` optional, mặc định null = hành vi hiện tại không đổi
- [ ] SDK tự chọn `AdSafetyParams` đúng mốc dựa trên `firstInstallAtMs`
- [ ] Test: qua các mốc tuổi install khác nhau, xác nhận đúng params được áp; không set schedule → hành vi y hệt cũ
