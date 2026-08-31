# T116 — Tech debt: Contract-test chung cho AdProviderAdapter

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `core/ad_provider_adapter.dart`, test `admob_*`, `applovin_*`, bridge fakes

## Vấn đề

Test 2 adapter nhiều nhưng parity chủ yếu được assert theo file riêng; lệch guard/callback/dispose thường chỉ lộ sau audit độc lập (đúng như T104/T105 vừa phát hiện). [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Reusable contract suite chạy CÙNG scenario matrix cho 2 provider: consent epoch, late callbacks, N instances, watchdog, revenue, dispose, show mutex
- [ ] Chỉ THÊM test, không đổi code sản xuất
- [ ] Chạy trong CI cho cả 2 adapter

## Ghi chú

Rủi ro thấp (chỉ thêm test). Nên làm TRƯỚC T114 (hợp nhất adapter) — làm lưới an toàn cho refactor đó.
