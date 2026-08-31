# T113 — Enhancement: AdPlacement.id(String) né giới hạn const-map

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P3 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/core/ad_safety_config.dart`, `test/ad_safety_config_test.dart`

## Vấn đề

T92 tự phát hiện `AdPlacement` override `==`/`hashCode` nên `const AdSafetyParams(maxPerPlacementAdsPerDay: {...})` KHÔNG compile được — đã document trong dartdoc/README nhưng chưa có API né tránh.

## Việc cần làm

- [x] ~~Factory `AdPlacement.id(String)`~~ — đã đọc kỹ: đây là giới hạn ngôn ngữ Dart thật (const map/set key không được override `==`), không constructor nào của CÙNG class `AdPlacement` sửa được việc đó bất kể tên gọi. Fix đúng: field mới `maxPerPlacementAdsPerDayById` kiểu `Map<String, int>?` (String có primitive equality) — dùng `AdPlacement.xxx.id` (getter `.id` đã có sẵn) làm key, không cần constructor mới.
- [x] Giữ nguyên API cũ (`maxPerPlacementAdsPerDay: Map<AdPlacement, int>?` không đổi) — chỉ thêm field `maxPerPlacementAdsPerDayById`, đọc ở `placementDailyCapReached` theo thứ tự: instance-map trước, id-map sau (fallback), không phải "conflict".
- [x] Test: `const AdSafetyParams(maxPerPlacementAdsPerDayById: {'splash': 1})` compile được + verify cap áp đúng cho `AdPlacement.splash`.
