# T108 — Enhancement: Retry policy cấu hình theo format + loại lỗi

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/state/backoff.dart`, `state/ad_slot.dart`, 2 adapter, `config/ad_config.dart`, `_retryRefillAds`

## Vấn đề

SDK đã có `Backoff` và watchdog nhưng chủ yếu dùng 1 policy chung; no-fill, network, invalid-request và timeout có ý nghĩa khác nhau. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Expose `AdRetryPolicy` per slot: max delay, jitter, retryable-error classifier, reset-on-connectivity
- [ ] Default giữ nguyên hành vi hiện tại (không breaking)
- [ ] Test: mỗi loại lỗi (no-fill/network/invalid/timeout) áp đúng policy tương ứng
