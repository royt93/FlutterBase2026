# T107 — Enhancement: AdPlacement typed xuyên suốt load/show/widget

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/state/ad_placement.dart`, `core/ad_manager.dart`, `core/ad_screen.dart`, các widget banner/MREC/native

## Vấn đề

`AdPlacement` đã tồn tại nhưng nhiều entry point vẫn nhận string/default placement ở các tầng khác nhau, làm host dễ typo và khó tái sử dụng cấu hình per-placement. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Overload nhận `AdPlacement` typed cho mọi format (load/show/widget)
- [ ] Factory/const catalog cho host
- [ ] Deprecate dần overload string (không breaking change)
- [ ] Test: mọi entry point mới có test typed placement tương đương bản string cũ
