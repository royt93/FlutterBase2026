# T93 — Ý tưởng: Deterministic A/B bucketing helper dùng install-id sẵn có

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart`

## Ý tưởng
`AdManager().experimentBucket(key, buckets: n)` tận dụng GAID/install-id đã có sẵn trong SDK, giúp host A/B test tham số `AdSafetyParams`/arbitrator threshold mà không cần tích hợp thêm dependency remote-config riêng (nhẹ hơn T88, không cần backend).

## Việc cần làm (đề xuất, chưa code)
- [ ] Hàm hash deterministic (install-id + key) → bucket index, ổn định qua nhiều lần gọi cùng install.
