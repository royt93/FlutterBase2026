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
đúng thứ gây treo. Không lặp lại sai lầm round-26 fix#5 (ép fix nhanh không
hiểu hết cơ chế).

## Bisect thêm (2026-08-31, phiên sau) — VẪN CHƯA TÌM RA, dừng lại đúng lúc

Dùng `flutter test test/ad_manager_core_test.dart --total-shards=N
--shard-index=i` (round-robin theo index test, xác nhận qua đối chiếu tập
hợp) để nhị phân tìm test/tổ hợp gây treo, mỗi lần bật tạm fix `await` rồi
chạy 1 shard với watchdog kill sau 40s:

- Chia đôi (2 shard): **shard 1/2 treo**, shard 0/2 chạy xong 8s (82 test).
- Chia tư (4 shard): trong 2 shard hợp thành shard 1/2 cũ, **shard 2/4 treo**
  (shard 3/4 chạy xong 8s).
- Chia tám, thử đúng 2 shard hợp thành shard 2/4 (xác nhận bằng round-robin:
  shard `i` của N-shard ⊃ shard `i` và shard `i+N/2` của (2N)-shard) — **CẢ
  HAI (2/8 và 6/8) ĐỀU CHẠY XONG BÌNH THƯỜNG, không treo cái nào.**

Tức là: treo chỉ xảy ra khi đủ SỐ LƯỢNG test lớn (≥ ~1/4 file, khoảng 40+
test) chạy chung 1 tiến trình, nhưng KHÔNG tái hiện được khi tách đúng tập
test đó thành 2 tiến trình nhỏ hơn. Đây không phải "1 test cụ thể gây treo"
mà giống **tích lũy trạng thái/tài nguyên theo số lượng test** (nghi ngờ:
timer/subscription/completer thật của platform-channel mock không được dọn
giữa các test trong `ad_manager_core_test.dart`, tới một ngưỡng thì
`_persistChain`/`flush()` của 1 `AdEventLog` nào đó chờ mãi 1 write không bao
giờ resolve). Đã dừng bisect ở đây — 6 lần chạy shard không đủ để tìm ra quy
luật, và nghi ngờ ban đầu (1 test `debugEventLog` cụ thể) đã bị loại (test đó
chạy 1 mình không treo, ở cả 2 lẫn 4 lẫn 8 shard).

**Không đoán bừa nguyên nhân sâu hơn.** Bước tiếp theo cho ai nhận lại ticket
này: cần công cụ khác `--total-shards` (round-robin làm việc tái hiện không
ổn định) — thử bisect bằng cách comment/`skip: true` từng nửa file theo THỨ
TỰ GỐC (không round-robin) để giữ đúng chuỗi tương tác giữa các test, hoặc
dùng `dart --observe`/timeline để bắt trực tiếp Future nào đang treo lúc
`flutter test` bị kill. Fix bằng timeout hữu hạn (không phải bỏ qua hoàn
toàn) vẫn là lựa chọn hợp lý NẾU điều tra sâu hơn xác nhận đây thật sự là
"chờ vô hạn 1 thứ không bao giờ tới" (test-only artifact) chứ không phải bug
thật trong `_persistChain`.
