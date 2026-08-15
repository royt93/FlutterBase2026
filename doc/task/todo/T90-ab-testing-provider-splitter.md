# T90 — Ý tưởng: A/B testing provider splitter (AdMob vs AppLovin MAX)

- **REQ:** audit round mới 2026-08-15 (agy + codex — "revenue-backed provider experiment")
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/event/ad_event.dart`, `packages/ad_sdk/lib/src/monetization/fill_rate_monitor.dart`, `packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart`

## Ý tưởng
Provider hiện chọn cố định lúc khởi động. Module phân chia traffic tự động (vd 50/50 dựa băm device id) kèm đo lường revenue/fill-rate cho phép app chủ so sánh trực quan hiệu quả 2 mạng quảng cáo — tận dụng event/fill-rate/arbitrator đã có sẵn, chỉ thiếu lớp experiment cohort + rollback.

## Việc cần làm (đề xuất, chưa code)
- [ ] Cohort assignment deterministic theo device id (có thể tái dùng ý tưởng T93).
- [ ] So sánh eCPM/fill giữa 2 cohort, expose qua compliance/debug report.
