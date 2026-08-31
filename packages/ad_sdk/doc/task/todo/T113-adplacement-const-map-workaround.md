# T113 — Enhancement: AdPlacement.id(String) né giới hạn const-map

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P3 · **Status:** 🔲 todo
- **Files:** `lib/src/state/ad_placement.dart`, `lib/src/core/ad_safety_config.dart`

## Vấn đề

T92 tự phát hiện `AdPlacement` override `==`/`hashCode` nên `const AdSafetyParams(maxPerPlacementAdsPerDay: {...})` KHÔNG compile được — đã document trong dartdoc/README nhưng chưa có API né tránh.

## Việc cần làm

- [ ] Factory `AdPlacement.id(String)` dùng String làm key thay vì instance `AdPlacement` trong riêng field `maxPerPlacementAdsPerDay`
- [ ] Giữ nguyên API cũ, chỉ thêm overload nhận `Map<String, int>`
- [ ] Test: `const` map với `AdPlacement.id(...)` compile được
