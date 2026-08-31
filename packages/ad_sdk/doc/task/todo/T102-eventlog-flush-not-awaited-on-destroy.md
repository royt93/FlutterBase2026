# T102 — _eventLog.flush() không await trước khi null hoá trong destroy()

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `lib/src/core/ad_manager.dart` (cuối `_destroy`), `lib/src/compliance/ad_event_log.dart`

## Vấn đề

`_destroy()` gọi `unawaited(_eventLog?.flush())` rồi đặt `_eventLog = null`. `destroy()` có thể hoàn tất và `initialize()` tạo log mới trước khi flush cũ ghi xong; log mới đọc dữ liệu cũ, hai session có thể ghi đè event của nhau ở đúng ranh giới lifecycle nhạy cảm. Ảnh hưởng compliance report/signing (T96). [đồng thuận — codex+agy]

## Việc cần làm

- [ ] await `flush()` có timeout hữu hạn trước khi null hoá, hoặc chuyển quyền sở hữu 1 shared persistence chain qua các session
- [ ] Test: destroy→initialize với delayed storage write, xác nhận không mất/đè event
