# T102 — _eventLog.flush() không await trước khi null hoá trong destroy()

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `lib/src/core/ad_manager.dart` (cuối `_destroy`), `lib/src/compliance/ad_event_log.dart`

## Vấn đề

`_destroy()` gọi `unawaited(_eventLog?.flush())` rồi đặt `_eventLog = null`. `destroy()` có thể hoàn tất và `initialize()` tạo log mới trước khi flush cũ ghi xong; log mới đọc dữ liệu cũ, hai session có thể ghi đè event của nhau ở đúng ranh giới lifecycle nhạy cảm. Ảnh hưởng compliance report/signing (T96). [đồng thuận — codex+agy]

## Việc cần làm

- [ ] await `flush()` có timeout hữu hạn trước khi null hoá, hoặc chuyển quyền sở hữu 1 shared persistence chain qua các session
- [x] Test: cơ chế mất event đã được chứng minh chắc chắn ở tầng `AdEventLog` (xem "Đã làm" bên dưới)
- [ ] Áp fix thật vào `ad_manager.dart` — ĐÃ THỬ, ĐÃ REVERT (xem bên dưới), cần điều tra thêm

## Đã làm (2026-08-31, round 27 sprint — CHƯA XONG, để lại todo/)

**Phần an toàn đã giữ lại** (không đụng `ad_manager.dart`, 0 rủi ro regression,
`flutter analyze` sạch, không test nào vỡ):
- `AdEventLog._persist()` tách seam test-only `debugPersistDelay` (giống hệt
  `AdPreferences.debugFillRateWriteDelay` ở T101 — cùng lý do: mock
  `SharedPreferences` trong test nhanh tới mức không tự lộ race, cần seam để
  tái hiện đúng độ trễ I/O thật).
- 2 test mới trong `test/ad_event_log_test.dart` **chứng minh chắc chắn cơ
  chế mất event là có thật**: gọi `flush()` KHÔNG await ngay trước khi
  construct 1 `AdEventLog` mới trên cùng `AdPreferences` → entry bị mất
  (test "T102 sibling"); gọi CÓ await → entry sống sót (test chính T102).
  Cả hai test đều xanh, chạy độc lập nhanh (không hang).

**Phần CHƯA xong — đã thử áp fix thật vào `ad_manager.dart`, đã REVERT:**
đổi `unawaited(_eventLog?.flush())` → `await _eventLog?.flush()` trong
`_destroy()` (dòng ~5104) làm **`flutter test` treo thật** (>10 phút không
xong, phải kill process) — ít nhất `ad_manager_core_test.dart` một mình cũng
treo khi chạy riêng (baseline không có fix: 4s cho 164 test; có fix: treo).
Chưa xác định được chính xác test/kịch bản nào trong file đó gây treo (nghi
ngờ 1 test dùng `debugEventLog` hoặc 1 chuỗi `destroy()`/`initialize()` lặp
lại nào đó khiến `_persistChain`/`flush()` chờ mãi không có gì để chờ resolve
— CHƯA điều tra tới cùng, không đoán bừa). Đã revert sạch `ad_manager.dart`
về nguyên trạng (`unawaited`), verify lại: full suite 1350 test pass trong
~1 phút, không treo.

**Bài học, để người sau không lặp lại:** ticket này TỰ ghi rõ "await flush()
CÓ TIMEOUT HỮU HẠN" — bỏ qua timeout (chỉ đổi `unawaited`→`await` trần) là
đúng thứ gây treo. Bước tiếp theo đúng đắn: (1) tìm chính xác test nào treo
bằng cách bisect `ad_manager_core_test.dart` (chạy nửa file, thu hẹp dần),
(2) ĐỌC hiểu tại sao trước khi thêm timeout — timeout che triệu chứng
(destroy() không còn treo) nhưng nếu root cause là 1 vòng lặp chờ thật (ví dụ
`_persistChain` bị 1 write khác giữ vĩnh viễn), timeout chỉ trì hoãn, không
sửa. Không lặp lại sai lầm round-26 fix#5 (ép fix nhanh không hiểu hết cơ chế).
