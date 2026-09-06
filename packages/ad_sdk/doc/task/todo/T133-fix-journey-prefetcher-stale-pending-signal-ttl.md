# T133 — Fix: JourneyPrefetcher không có TTL cho pending signal, đè sai rolling average

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
  Xem `doc/audit/audit_round41.md` cho context audit liên quan.
- **Priority:** P2
- **Status:** 🔲 todo
- **Effort:** S
- **Files (dự kiến):** `packages/ad_sdk/lib/src/monetization/journey_prefetcher.dart`
- **Nguồn gợi ý:** codex + agy đồng thuận (đã tự verify lại cơ chế thật, mô
  tả gốc "kéo lên hàng giờ" hơi không chính xác — xem "Vấn đề" bên dưới cho
  mô tả đúng sau khi đọc code)
- **Dependency:** (không có)

## Vấn đề

`journey_prefetcher.dart` — `notifySignal()` (dòng 111-134) ghi
`_lastSignalAt[key] = _now()` mỗi lần được gọi; `_onEvent()` (dòng 71-96)
chỉ xoá entry đó khỏi `_lastSignalAt` khi có 1 `AdShowEvent` thành công
KHỚP loại (`type`) xảy ra sau đó, và entry được xoá là entry "mới nhất"
đang chờ cho loại đó (theo `_lastSignalSeq`). Không có bất kỳ TTL/expiry
nào cho các entry đang chờ.

**Kịch bản lỗi thật (đã tự verify bằng đọc code, không phải đoán):**
1. Host gọi `notifySignal("levelStarted", AdSlotType.interstitial)`.
2. App bị đưa xuống nền (backgrounded) một khoảng thời gian dài (không
   phải đóng hẳn — object `JourneyPrefetcher` vẫn sống trong process,
   `_lastSignalAt` không bị reset), sau đó user quay lại app.
3. Một interstitial cuối cùng CŨNG được show (có thể vì lý do hoàn toàn
   khác, không liên quan tới "levelStarted" ban đầu) — `_onEvent` vẫn
   khớp show event này với entry `"levelStarted|interstitial"` vì đó là
   entry pending gần nhất cho loại `interstitial`, bất kể khoảng cách
   thời gian thực tế bao lâu.
4. `elapsed` (khoảng cách backgrounding, có thể rất dài) bị ghi thẳng vào
   `_timeToShow` như 1 sample thời gian "chờ show" bình thường, kéo rolling
   average lên cao bất thường — nếu vượt `maxHoldDuration`, `notifySignal`
   cho key đó sẽ **ngừng preload eager vĩnh viễn** (cho tới khi đủ 10 sample
   mới trong rolling window đè hết sample bất thường này ra).

Đây là outlier do backgrounding bị hiểu nhầm thành "gameplay pacing chậm
thật", không phải leak bộ nhớ không giới hạn như mô tả brainstorm ban đầu
("kéo lên hàng giờ" là 1 kịch bản CÓ THỂ xảy ra, không phải luôn luôn) —
nhưng hệ quả (vô hiệu hoá preload sai) là thật và đáng sửa.

**Gap phụ (minor, không cần fix riêng — sẽ tự hết khi sửa cái trên):** nếu
1 signal được gọi 1 lần rồi KHÔNG BAO GIỜ được gọi lại và ad khớp loại đó
cũng không bao giờ show (đường journey bị bỏ luôn), entry đó nằm trong
`_lastSignalAt`/`_lastSignalSeq` tới khi app đóng hẳn (object bị huỷ theo
process, không phải leak vĩnh viễn qua nhiều lần mở app — cần xác nhận
`JourneyPrefetcher` không persist gì xuống disk, chỉ in-memory, đã đọc code
xác nhận đúng vậy, chỉ dùng `Map` thuần).

## Việc cần làm

- [ ] Thêm ngưỡng tuổi tối đa cho 1 pending signal (ví dụ tham số mới
      `maxPendingAge` hoặc tái dùng `maxHoldDuration` — cân nhắc kỹ, 2 khái
      niệm khác nhau: "chờ show quá lâu thì đừng preload nữa" (đã có) vs
      "signal đã chờ quá lâu thì coi như đã hết hạn, đừng tính vào sample"
      (đang thiếu) — nên có tham số riêng, hoặc dùng chung `maxHoldDuration`
      làm ngưỡng luôn nếu 2 ý nghĩa gộp được mà không gây nhầm, tự quyết
      định khi đọc kỹ hơn).
- [ ] Trong `_onEvent`, trước khi coi 1 entry pending là match hợp lệ, kiểm
      tra tuổi của entry đó (`_now().difference(latestAt)`) — nếu đã vượt
      ngưỡng, coi như "quá hạn", KHÔNG tính vào `_timeToShow` (không thêm
      sample), chỉ xoá entry pending đó đi (không cần quan tâm show event
      này nữa vì đã quá xa journey gốc).
- [ ] Test: mô phỏng `notifySignal` rồi advance debug clock (`debugClock`
      seam đã có sẵn ở constructor) vượt ngưỡng, rồi bắn `AdShowEvent`
      thành công cùng loại — verify KHÔNG có sample mới được thêm vào
      `_timeToShow`/`averageTimeToShow` (vẫn `null` hoặc giữ nguyên như
      trước), và entry pending bị xoá.
- [ ] Không cần backend/remote — thuần logic on-device trong class này.

## Ghi chú

Effort S vì class nhỏ (140 dòng), đã có sẵn `debugClock` seam để test time
travel không cần chờ thật. Rủi ro chính: chọn sai ngưỡng mặc định (quá
ngắn thì coi journey bình thường là "quá hạn" sai, quá dài thì không giải
quyết được vấn đề thật) — nên tham khảo `maxHoldDuration`'s default (5
phút) làm điểm khởi đầu hợp lý cho ngưỡng mới, hoặc dùng chung luôn nếu ý
nghĩa gộp lại rõ ràng.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T133-fix-journey-prefetcher-stale-pending-signal-ttl.md này (nếu đã chuyển sang inprogress/
hoặc done thì đọc ở đó). Implement ĐÚNG scope mô tả trong "Việc cần làm" —
KHÔNG thêm scope ngoài mô tả.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có (kiểu RemoteAdSafetyProvider), không tự
dựng server/API mới. Nếu ticket này có vẻ cần backend, dừng lại hỏi user
trước khi code.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate đã dùng ở round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp lại: sửa → audit adversarial (có thể dùng codex/agy độc lập trong bản
copy cô lập /tmp, KHÔNG cp -R nguyên khối tránh ENOSPC, dùng rsync loại trừ
build/.dart_tool/Pods/.gradle) → nếu điểm ≤9/10 thì sửa tiếp theo finding →
verify lại → lặp tới khi ≥9/10 mới push. KHÔNG tự ý push nếu chưa đạt
ngưỡng. Di chuyển file ticket này từ todo/ sang inprogress/ khi bắt đầu,
sang done/ khi xong.
```
