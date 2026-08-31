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

## Lần thử thứ 3 (2026-09-01) — TÌM RA THỦ PHẠM CỤ THỂ, chưa fix

Bỏ chiến lược round-robin sharding (lần 2 dùng, không ra). Lần này: áp lại
`await _eventLog?.flush()` rồi chạy TỪNG GROUP riêng bằng `--plain-name`
(có watchdog 60s ngoài + timeout mặc định 30s/test của package:test).

**Thủ phạm: group `remoteSafetyProvider (T88)`, test `'a provider slower
than the 5s timeout falls back to local params'`** (dùng
`_HangingRemoteSafetyProvider` — 1 `Completer` cố tình không bao giờ
complete, bọc trong `fakeAsync(() { unawaited(AdManager().initialize(...));
async.elapse(Duration(seconds: 6)); ... })`).

Chạy riêng group này với `await` bật: **test tự nó treo, hit đúng timeout
mặc định 30s của package:test** — tái hiện được trong 30s, không cần đợi
10 phút như lần 1. Baseline (không có fix `await`) test này chạy nhanh bình
thường.

**Manh mối đã có sẵn ngay phía trên group này** (comment do 1 session trước
để lại khi thêm T111): thêm bất kỳ test `AdMobAdapter.initialize()` thật nào
NGAY SAU test `_HangingRemoteSafetyProvider` này "triggered a deterministic
(not flaky) google_mobile_ads internal null check... leaves its real GMA
init orphaned rather than cancelled" — session đó đã né bằng cách tách hẳn
T111 sang file riêng (`test/refresh_remote_safety_params_test.dart`), KHÔNG
sửa root cause.

**Cơ chế nghi ngờ (chưa xác nhận 100%, cần thêm 1 vòng điều tra để chắc
trước khi fix):** `fakeAsync(...)` chỉ kiểm soát `Timer`/`Future.delayed` ẢO
— `async.elapse(6s)` khiến timeout nội bộ 5s (thứ bọc
`fetchSafetyParamOverrides()`) fire đúng trong zone ảo. Nhưng
`AdManager().initialize()` gọi `unawaited` (không `await`) nên hàm test kết
thúc và `fakeAsync` zone đóng lại TRƯỚC KHI phần còn lại của `initialize()`
(sau khi bắt được timeout, tiếp tục qua các bước dùng platform channel THẬT
— GMA/AppLovin mock — không chịu sự kiểm soát của `fakeAsync`) chạy xong.
Phần đuôi đó tiếp tục chạy ở REAL wall-clock time sau khi zone ảo đã đóng,
và với `unawaited(_eventLog?.flush())` (bản gốc) không ai chờ nó nên hang
"vô hình" — không exception, không hiện tượng gì trong CHÍNH test đó. Đổi
sang `await` khiến `tearDown` (`await AdManager().destroy()`) của CHÍNH
test này giờ phải chờ đúng cái đuôi bị bỏ rơi đó — và cái đuôi đó không bao
giờ tự hoàn tất vì nó phụ thuộc 1 phần trạng thái/mock đã bị zone
`fakeAsync` đóng cắt đứt.

**Vì sao chưa fix ở lần này:** đây là lỗi TEST (fakeAsync dùng sai cho 1
kịch bản có tác vụ platform-channel thật lọt qua zone ảo), không hẳn là bug
`ad_manager.dart`. Sửa đúng cách cần 1 trong các hướng sau, MỖI HƯỚNG ĐỀU
CẦN TỰ VERIFY KỸ chứ không phải đoán:
1. Đổi test không dùng `fakeAsync` cho kịch bản `_HangingRemoteSafetyProvider`
   nữa — chờ thật 6s (chấp nhận test chậm hơn 6s) để không có phần đuôi thật
   nào lọt qua ranh giới zone ảo.
2. Hoặc: trong chính test, sau `async.elapse(6s)`, gọi thêm
   `await AdManager().initialize(...)` (đợi thật, ngoài zone ảo) trước khi
   test kết thúc, để phần đuôi thật có cơ hội chạy xong trong THỜI GIAN CỦA
   CHÍNH TEST đó thay vì tràn sang `tearDown`/test sau.
3. Hoặc: `AdManager.initialize()`'s timeout-catch cho remoteSafetyProvider
   cần tự đảm bảo KHÔNG còn future thật nào treo lại sau khi bắt timeout —
   audit lại chính đoạn code đó (không phải chỉ test) xem có await nào lồng
   bên trong provider-fetch mà timeout không thực sự huỷ được nó (Dart
   `.timeout()` không cancel Future gốc, chỉ ngừng CHỜ nó — future gốc vẫn
   chạy nền và có thể mutate state sau này).

Hướng (3) có khả năng là ROOT CAUSE THẬT SỰ đáng ưu tiên điều tra trước —
khớp đúng bài học "Dart Future.timeout() không hủy Future gốc" là 1 lớp bug
kinh điển, và giải thích được vì sao `unawaited()` "che" được vấn đề (không
ai chờ effect phụ của future gốc vẫn chạy ngầm) trong khi `await` làm lộ nó
ra (chờ đúng vào effect phụ đó thông qua `_eventLog`/`_persistChain` bị đụng
chung).

**Việc tiếp theo cho phiên sau:** đọc kỹ code xử lý `remoteSafetyProvider`
timeout trong `ad_manager.dart` (`initialize()`, đoạn gọi
`fetchSafetyParamOverrides().timeout(...)`) — xác nhận future gốc có bị bỏ
rơi (không `catchError`/không có nơi nó ghi vào state chung) hay không. Nếu
đúng, fix ở ĐÓ (ví dụ đảm bảo future gốc luôn có `.catchError`/không đụng
state sau khi bị timeout) có thể tự động giải quyết luôn cả T102 THẬT (vì đó
mới là cái để lại "hiệu ứng phụ chạy ngầm" mà `await` sau này vô tình chờ
phải) — không chỉ né bằng cách sửa lại 1 test.

**Cập nhật (phiên chính, cùng ngày) — đã tự đọc hướng (3), khả năng thấp
hơn dự đoán:** `ad_manager.dart:2460-2474` (`initialize()`'s remote-safety
fetch) đã `await ... .timeout(Duration(seconds: 5))` bọc trong `try/catch`
đúng chuẩn — timeout throw, catch bắt, `initialize()` tiếp tục ngay, không
có gì "await treo" ở CHÍNH đoạn này. Future gốc (Completer không bao giờ
complete của provider giả trong test) đúng là bị bỏ rơi (Dart `.timeout()`
không cancel future gốc — biết trước), nhưng bỏ rơi 1 future không tự nó
gây treo trừ khi có gì sau này CHỦ ĐỘNG chờ lại đúng future đó hoặc 1 side
effect của nó. Nghi vấn giờ nghiêng hẳn về **hướng (1)** — lỗi nằm trong
CHÍNH TEST (`_HangingRemoteSafetyProvider` test, dùng `fakeAsync` sai cho 1
kịch bản có platform-channel thật lọt qua zone ảo), không phải bug
`ad_manager.dart`. Việc tiếp theo hợp lý nhất: sửa test đó theo hướng (1)
(bỏ `fakeAsync`, chờ thật 6s) — rủi ro thấp nhất vì không đụng code sản
xuất, và nếu sau khi sửa test mà `await` (fix T102 thật) vẫn không treo nữa
thì xác nhận đây đúng là lỗi test, đóng được T102 bằng cách sửa TEST + áp
lại fix `await` trong `destroy()`.

## ĐÃ ĐÓNG (2026-09-01, version 2.9.4) — hướng (1) đúng, xác nhận 100%

Sửa `test/ad_manager_core_test.dart`'s `'a provider slower than the 5s
timeout falls back to local params'`: bỏ `fakeAsync`, `await
AdManager().initialize(...)` thật thay vì `unawaited` + `async.elapse(6s)`.
Lý do đúng như nghi vấn hướng (1): test cũ chỉ elapse thời gian ẢO rồi kết
thúc ngay, để `initialize()`'s phần đuôi (native platform-channel thật,
không nằm trong tầm kiểm soát của `fakeAsync`) tiếp tục chạy ở real
wall-clock time SAU KHI zone ảo đã đóng. `unawaited(_eventLog?.flush())`
(bản cũ) không ai chờ nên "che" được cái đuôi mồ côi đó; đổi sang `await`
làm `destroy()`'s tearDown phải chờ đúng cái đuôi không bao giờ tự xong đó
→ treo. Sửa test dùng thời gian thật (không mix 2 zone) loại bỏ hẳn cái
đuôi mồ côi — không phải bug `ad_manager.dart`.

Áp lại fix thật: `unawaited(_eventLog?.flush())` → `await
_eventLog?.flush()` trong `destroy()`. Verify:
- `test/ad_manager_core_test.dart` (165 test, toàn bộ file) chạy trong ~8s,
  không treo.
- Full suite: **1476 test pass** (thêm `test/destroy_awaits_event_log_flush_test.dart`,
  test AdManager-level chứng minh trực tiếp qua `debugEventLog` +
  `AdEventLog.debugPersistDelay`, mutation-verified: revert → đỏ đúng chỗ
  (destroy() trả về sau ~7ms thay vì chờ đủ 60ms delay), fix lại → xanh).
- `flutter analyze` sạch.

**Bài học cho lần sau nếu gặp treo tương tự:** đừng nghi code sản xuất
trước — nếu hang chỉ xuất hiện khi ĐỔI 1 chỗ từ `unawaited`→`await`, khả
năng cao là code cũ vốn đã có 1 "cái đuôi mồ côi" (orphaned tail) ẩn sẵn ở
đâu đó (thường do mock/fakeAsync/timeout không thật sự huỷ được future gốc),
và `await` chỉ đơn giản làm nó LỘ RA chứ không phải là nguyên nhân — bisect
đúng chỗ (test riêng lẻ, không phải shard ngẫu nhiên) tìm ra rất nhanh.
