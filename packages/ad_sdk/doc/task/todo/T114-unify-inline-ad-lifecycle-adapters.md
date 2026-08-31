# T114 — Tech debt: Hợp nhất lifecycle keyed inline-ad giữa 2 adapter

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `adapters/admob_adapter.dart`, `applovin_adapter.dart`, `_inline_visibility.dart`, 3 widget inline

## Vấn đề

Banner/MREC/native có nhiều map instance, sentinel warmup key, listenable disposal và revive logic gần giống nhau nhưng triển khai lặp ở AdMob/AppLovin — chính là lý do bug T105 (guard onAdOpened/onAdClicked) và T104 (tombstone leak) tồn tại: fix 1 bên quên bên kia. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Internal generic `InlineAdInstanceRegistry<TAd>` quản lý ownership, notifier, generation và dispose
- [ ] Bridge/adapter chỉ cung cấp load/destroy callback
- [ ] KHÔNG đổi public API
- [ ] Giữ 100% test coverage hiện có trong lúc refactor

## Ghi chú

Effort XL, rủi ro cao trên 2 file đã audit 26 vòng riêng biệt. **Nên làm SAU T116 (contract-test chung, DEBT-4)** để có lưới an toàn trước khi gộp code — dù user chọn "làm ngay" cho câu hỏi độ ưu tiên, thứ tự kỹ thuật vẫn nên tôn trọng dependency này. Không nên bắt đầu code tới khi T116 done.
