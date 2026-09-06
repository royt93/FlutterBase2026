# T134 — Enhancement: Harden AdReadinessSplashController chống gọi start() 2 lần

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
  Xem `doc/audit/audit_round41.md` cho context audit liên quan.
- **Priority:** P3 (hạ từ P2 gốc sau khi tự verify — xem "Vấn đề" bên dưới,
  mức độ rủi ro thật nhẹ hơn brainstorm mô tả)
- **Status:** 🔲 todo
- **Effort:** S
- **Files (dự kiến):** `packages/ad_sdk/lib/src/widget/ad_readiness_splash_controller.dart`
- **Nguồn gợi ý:** codex (KHÔNG tự verify ở brainstorm gốc) — ticket này đã
  tự đọc code lại kỹ, kết luận khác brainstorm gốc, xem ghi chú dưới
- **Dependency:** (không có)

## Vấn đề (đã điều chỉnh sau khi tự verify — khác brainstorm gốc)

Brainstorm gốc mô tả đây là "không idempotent khi start() gọi 2 lần đè
listener/context của lần đầu (leak/race)". Đọc kỹ `start()` (dòng 75-114)
thì thực tế **nhẹ hơn** vậy:

- `AdManager().incrementSplashCount()` gọi mỗi lần `start()` chạy — nếu
  `start()` bị gọi 2 lần trên CÙNG 1 instance (trong cùng phiên app, chưa
  `dispose()`), `countInitSplashScreen` sẽ tăng lên >1 ở lần gọi thứ 2,
  trùng đúng nhánh guard đã có sẵn (dòng 89-92: "Re-entered while previous
  splash instance still on stack") — nhánh này vốn viết cho kịch bản khác
  (user mở lại app, 1 instance MỚI được tạo) nhưng **tình cờ cũng chặn**
  được luồng thứ 2 chạy full lại (không tạo Timer/listener thứ 2, không
  gọi `initialize()` lần nữa) — chỉ gọi thẳng `_goReady()`.
- `_goReady()` tự có guard `if (_navigated) return;` (dòng 151) nên gọi
  nhiều lần không sao — không có 2 `Timer`/`_busListener` cùng tồn tại
  chạy song song thật sự trong kịch bản double-start đơn giản.
- Class tự document ngay ở doc comment (dòng 74): **"Safe call only once
  per controller instance."** — đây là hợp đồng caller đã ghi rõ, KHÔNG
  phải oversight ẩn.

**Rủi ro thật còn lại (nhỏ hơn "leak/race" ban đầu mô tả):** nếu `start()`
bị gọi 2 lần với `onReady`/`context` KHÁC NHAU (context đầu tiên có thể đã
navigate/dispose), field `_context`/`_onReady` bị ghi đè bởi lần gọi thứ 2
— nếu flow của LẦN GỌI ĐẦU (Timer/event bus) cuối cùng fire trước khi
short-circuit của lần 2 kịp chạy (race hẹp, cùng frame), `_goReady()` có
thể gọi `_onReady` (đã bị ghi đè thành callback của lần 2) với ngữ cảnh
không khớp — silent behavior sai, không crash, khó debug nếu ai đó vô tình
gọi `start()` 2 lần (ví dụ do lỗi ở code gọi, không phải lỗi trong chính
class này).

## Việc cần làm

- [ ] Thêm field `bool _started = false;`, set `true` ngay đầu `start()`.
- [ ] Nếu `start()` được gọi khi `_started == true` — log cảnh báo rõ ràng
      (`SafeLogger.w` hoặc tương đương pattern dùng trong file khác cùng
      thư mục) mô tả đây là lỗi dùng sai API (gọi `start()` 2 lần trên
      cùng 1 instance), rồi `return` ngay — KHÔNG chạy lại field
      overwrite/incrementSplashCount/Timer/listener nào, không dựa vào
      `countInitSplashScreen` guard tình cờ như hiện tại (guard đó viết
      cho mục đích khác, dùng nhầm chỗ này là fragile).
- [ ] Test: gọi `start()` 2 lần liên tiếp trên cùng instance (mock context)
      — verify lần gọi thứ 2 log cảnh báo, KHÔNG override `_onReady`, và
      `AdManager().incrementSplashCount()`/`markSplashActive()` chỉ được
      gọi ĐÚNG 1 lần (dùng seam/mock đã có sẵn trong test suite hiện tại
      của class này — xem file test tương ứng nếu có, tái dùng pattern).
- [ ] Không cần backend/remote — thuần defensive-programming on-device.

## Ghi chú

Effort S, priority hạ xuống P3 vì đây là HARDEN cho 1 misuse-case đã được
document rõ, không phải bug đang âm thầm gây hại thật trong luồng dùng
đúng (SplashScreen chỉ gọi `start()` 1 lần trong `initState()`, Flutter
không tự gọi lại `initState()` trong vòng đời bình thường của 1 State).
Vẫn đáng làm vì rẻ (effort S) và làm API khó dùng sai hơn, nhưng không
khẩn cấp như T132.

## Kết quả (2026-09-06) — DONE

- **Status:** ✅ done. **Điểm: 9.2/10** (1 vòng review độc lập `codex`, PUSH
  ngay).
- Thêm `bool _started`, guard đầu `start()` — độc lập hoàn toàn với
  `countInitSplashScreen` (guard cũ giữ nguyên mục đích gốc của nó).
- 2 finding non-blocking (reviewer tự nói "không đáng giữ lại push"): test
  dùng chung 1 counter cho cả 2 callback (không tách riêng chứng minh
  callback đầu KHÔNG bị ghi đè) — chấp nhận, thứ tự code đã rõ ràng qua
  đọc trực tiếp; comment ban đầu hơi phóng đại hành vi lỗi cũ (nói "luôn
  restart timer" trong khi thực tế chỉ xảy ra ở race hẹp) — đã sửa lại
  comment cho chính xác.
- Baseline: `flutter analyze` sạch; `flutter test` 1698/1698; integration
  test `t134_splash_controller_double_start_test.dart` pass thật trên
  Pixel 7 Pro.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T134-harden-ad-readiness-splash-controller-double-start.md này (nếu đã chuyển sang inprogress/
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
