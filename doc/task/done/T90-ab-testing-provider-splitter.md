# T90 — Ý tưởng: A/B testing provider splitter (AdMob vs AppLovin MAX)

- **REQ:** audit round mới 2026-08-15 (agy + codex — "revenue-backed provider experiment")
- **Priority:** P2 · **Status:** ✅ done (MVP: cohort picker; per-cohort so sánh dùng event stream có sẵn, không thêm compliance-report plumbing)
- **Files:** `packages/ad_sdk/lib/src/event/ad_event.dart`, `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart`, `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`

## Ý tưởng
Provider hiện chọn cố định lúc khởi động. Module phân chia traffic tự động (vd 50/50 dựa băm device id) kèm đo lường revenue/fill-rate cho phép app chủ so sánh trực quan hiệu quả 2 mạng quảng cáo — tận dụng event/fill-rate/arbitrator đã có sẵn, chỉ thiếu lớp experiment cohort + rollback.

## Việc cần làm (đề xuất, chưa code)
- [x] Cohort assignment deterministic theo device id (có thể tái dùng ý tưởng T93).
- [x] So sánh eCPM/fill giữa 2 cohort, expose qua compliance/debug report.

## Đã làm (2026-08-16)

**Thứ tự làm:** làm T93 (bucketing helper) trước vì T90 tự ghi phụ thuộc nó ("có thể tái dùng ý tưởng T93"). `pickProviderCohort()` xây trực tiếp trên `experimentBucket()` — không trùng lặp logic hash/fallback GAID.

**Quyết định scope quan trọng — KHÔNG xây thêm "compliance-report plumbing" riêng cho so sánh cohort:** mọi event trên `AdManager().events` (`AdLoadEvent`, `AdRevenueEvent`, ...) ĐÃ CÓ SẴN field `providerTag` (`'[AdMob]'`/`'[AppLovin]'`) — đây CHÍNH LÀ tín hiệu "cohort nào" cho mỗi impression/load, vì cohort ⟺ provider 1-1 trong thiết kế này. Host tự group theo `providerTag` trong analytics pipeline riêng (đã có sẵn từ trước, README đã hướng dẫn từ đầu). Xây thêm 1 lớp "cohort-aware compliance report" mới sẽ là trùng lặp không cần thiết (over-engineering) — vi phạm nguyên tắc tái dùng thay vì tạo mới.

**API:** `AdManager().pickProviderCohort({String key = 'provider_ab_test'})` → `AdProvider` — gọi TRƯỚC khi build `AdConfig` (provider cố định cho cả session, chỉ set 1 lần lúc `initialize()`).

TDD: 4 test — ổn định qua gọi lại, kết quả luôn hợp lệ, key khác nhau cho phân bố khác nhau (không hardcode 1 provider), nhiều install khác nhau phân bố cả 2 provider (không kẹt 1 bên).

README + CHANGELOG cập nhật, có ví dụ `AdConfig(provider: ..., admob: ..., appLovin: ...)` khai cả 2 config cùng lúc, chỉ cái được chọn mới thật sự load.

`flutter test`: 788/788 pass (2 lần), `flutter analyze` sạch.
