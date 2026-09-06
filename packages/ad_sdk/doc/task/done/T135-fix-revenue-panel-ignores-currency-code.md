# T135 — Fix: RevenuePanel cộng dồn revenue bỏ qua currencyCode

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
  Xem `doc/audit/audit_round41.md` cho context audit liên quan.
- **Priority:** P3 (xem "Ghi chú" — rủi ro thật thấp trong thực tế hiện tại,
  hạ từ P2 giả định ban đầu trong brainstorm)
- **Status:** 🔲 todo
- **Effort:** S
- **Files:** `packages/ad_sdk/lib/src/widget/revenue_panel.dart` — **đây là
  code SDK thật (`lib/`), KHÔNG phải chỉ demo trong `example/`** — đã verify
  bằng grep, sửa ticket gốc (brainstorm nghi ngờ có thể chỉ ở example).
- **Nguồn gợi ý:** agy (đã tự verify lại đúng, có 1 chi tiết brainstorm gốc
  không nhắc tới — xem "Vấn đề")
- **Dependency:** (không có)

## Vấn đề

`revenue_panel.dart:42,59` — `_totalUsd` (tên biến ngụ ý luôn là USD) được
cộng dồn bằng `_totalUsd.value + event.value`, trong đó `event.value` (định
nghĩa ở `ad_event.dart:157`: `double get value => valueMicros / 1000000.0`)
**là phép chia số học thuần, không hề tham chiếu `event.currencyCode`**
(field có tồn tại thật, `ad_event.dart:128,138`, kiểu `String`, ví dụ
`'USD'`). Nếu 1 `AdRevenueEvent` nào đó có `currencyCode` khác `'USD'`
(không phổ biến nhưng field tồn tại đúng vì lớp dữ liệu này chủ ý không
loại trừ khả năng đó), `RevenuePanel` vẫn cộng thẳng số vào cùng 1 tổng và
hiển thị với ký hiệu `\$` cứng (dòng 87, 103) — kết quả hiển thị sai đơn vị
tiền tệ, không có cảnh báo gì cho host app.

**Đánh giá rủi ro thực tế (quan trọng, brainstorm gốc không nêu):** cả
Google AdMob và AppLovin MAX đều được biết là **luôn báo `currencyCode =
"USD"`** cho estimated/paid revenue của publisher, bất kể tài khoản host ở
đâu — đây là hành vi tài liệu hoá của cả 2 network gốc. Vì vậy trong thực
tế hiện tại (chỉ AdMob + AppLovin, không mediation network TQ như CSJ —
xem T131), field `currencyCode` gần như luôn là `"USD"`, nên bug này **khó
kích hoạt thật trong sử dụng thông thường** — đây là 1 code smell/thiếu
phòng thủ hơn là 1 lỗi đang âm thầm gây sai số liệu hôm nay.

## Việc cần làm

- [ ] Trong `_onEvent`, kiểm tra `event.currencyCode` trước khi cộng dồn
      vào `_totalUsd` — nếu khác `'USD'`, KHÔNG cộng lẫn vào cùng 1 tổng.
      Lựa chọn thiết kế (chọn 1 khi implement, không cần cả 2):
      (a) đơn giản nhất — bỏ qua (không cộng, log cảnh báo 1 lần) event có
      currency khác USD, giữ nguyên UI đơn giản hiện tại (chấp nhận số
      liệu thiếu chính xác nếu thật sự có currency khác, nhưng không còn
      SAI đơn vị hiển thị); hoặc
      (b) đầy đủ hơn — gom theo `currencyCode` thành `Map<String, double>`,
      hiển thị dòng riêng cho mỗi currency khác USD nếu có phát sinh (chỉ
      cần khi Map có >1 key, mặc định vẫn hiển thị như cũ nếu chỉ có USD).
- [ ] Test: bắn 1 `AdRevenueEvent` với `currencyCode: 'EUR'` — verify không
      bị cộng lẫn vào tổng USD hiển thị (theo đúng lựa chọn thiết kế ở
      trên).
- [ ] Không cần backend/remote — thuần hiển thị on-device.

## Ghi chú

Effort S — widget nhỏ (120 dòng), logic thêm chỉ là 1 nhánh check
`currencyCode` trước khi cộng. Priority P3 vì rủi ro thực tế thấp (xem
đánh giá ở trên) — vẫn đáng làm vì rẻ và đúng-về-nguyên-tắc (`RevenuePanel`
là widget công khai của SDK, không nên âm thầm giả định currency), nhưng
không cấp bách bằng T132 (race thật, đã tự verify gây sai state thật).

## Kết quả (2026-09-06) — DONE

- **Status:** ✅ done. **Điểm: 9.5/10** (1 vòng review độc lập `codex`, PUSH
  ngay).
- Chọn option (a) — bỏ qua event khác USD (không cộng vào `_totalUsd`),
  log cảnh báo 1 lần qua `_warnedNonUsd`, impression vẫn tăng bình thường.
- **Bug tự bắt được khi viết test (không phải bug ở code sửa)**: phát hiện
  `AdManager().events` là broadcast StreamController không đồng bộ +
  `ValueListenableBuilder` cần thêm 1 frame sau `setState()` — cần **2 lần
  `pump()`** sau mỗi `debugEmit()` mới thấy được UI cập nhật trong test
  (1 lần không đủ). Không phải lỗi trong `revenue_panel.dart`, chỉ là
  pattern test cần đúng cho mọi widget nghe `AdManager().events`.
- Baseline: `flutter analyze` sạch; `flutter test` 1702/1702; integration
  test `t135_revenue_panel_currency_guard_test.dart` pass thật trên
  Samsung Galaxy S24 Ultra (Pixel 7 Pro mất kết nối giữa session, dùng
  máy Android khác sẵn có).

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T135-fix-revenue-panel-ignores-currency-code.md này (nếu đã chuyển sang inprogress/
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
