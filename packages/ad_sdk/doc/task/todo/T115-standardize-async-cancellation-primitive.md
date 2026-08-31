# T115 — Tech debt: Chuẩn hoá primitive huỷ callback async

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `ad_manager.dart`, 2 adapter, UMP, VIP manager, splash controller, loading dialog

## Vấn đề

Code dùng lẫn generation int, bool disposed, timer, identity check và `Completer` — correctness hiện phụ thuộc comment dài tại từng call site. [đồng thuận 3 nguồn]

## Việc cần làm

- [ ] Internal `OperationToken`/`AsyncEpoch` thống nhất `isCurrent`, invalidate và bounded await
- [ ] Migrate từng subsystem một, giữ timing hiện tại bằng fake clock test
- [ ] KHÔNG đổi hành vi observable — chỉ đổi cách biểu diễn nội bộ
