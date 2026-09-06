# T136 — Enhancement: WaterfallTuner/SelfHealingObserver hoạt động thật trên device (on-device only)

- **REQ:** brainstorm round 43 (2026-09-06) — đọc source thật + tham khảo
  `codex`/`agy` độc lập trong bản copy cô lập, user chọn qua AskUserQuestion.
- **Priority:** P1
- **Status:** 🔲 todo
- **Effort:** L
- **Files (dự kiến):** `lib/src/monetization/waterfall_tuner.dart`,
  `lib/src/monetization/self_healing_observer.dart`, `lib/src/core/ad_manager.dart`
  (`enableWaterfallTuner`/`enableSelfHealingObserver`/`pickProviderCohort`),
  `lib/src/config/ad_config.dart` (nếu cần thêm config field)
- **Nguồn gợi ý:** codex + agy đồng thuận — gap lớn nhất toàn bộ monetization layer
- **Dependency:** không

## Vấn đề

Cả hai class đã tự nhận trong chính doc comment của mình là code chết trên
mọi install thật:

- `waterfall_tuner.dart:69` (docstring ngay trên `class WaterfallTuner`):
  "no shadow ad ever requested [for the] non-active provider — every score
  comes [from] load/revenue events SDK already produces" — và class chỉ
  hữu ích cho "provider-cohort A/B experiments ACROSS installs ... via
  server-side analytics", không phải trong 1 install.
- `self_healing_observer.dart:21-27` (Round-31 audit note): "this observer
  will sit silent forever on any real install, not 'wait for enough data'"
  — vì `WaterfallTuner` nó bọc bên trong chỉ thấy event của 1 provider
  (provider đang chạy), provider kia mãi mãi rỗng dữ liệu trong SUỐT VÒNG
  ĐỜI của install đó, vì SDK chỉ chạy 1 provider/session
  (`AdConfig.provider`).

Cơ chế cross-install đã có sẵn (`pickProviderCohort()`,
`ad_manager.dart:474`, hash-bucket theo `provider_ab_test` key) chỉ chọn
provider 1 LẦN ở lúc cài đặt — không giúp 1 install ĐANG CHẠY thấy được
provider kia hoạt động ra sao.

**SDK này KHÔNG dùng remote config/backend** — nên hướng "server-side
analytics tổng hợp qua nhiều install" mà doc comment gợi ý KHÔNG áp dụng
được. Cũng KHÔNG được shadow-request provider kia (chính doc comment đã từ
chối hướng này vì tốn inventory/rủi ro policy, round-31 audit ghi rõ đây là
quyết định có chủ đích, không phải thiếu sót).

**Phát hiện phụ (liên quan, không mở rộng scope ticket này):**
`waterfall_tuner.dart:91` cộng dồn `event.valueMicros` không hề đọc
`event.currencyCode` (field đã có sẵn ở `AdRevenueEvent`,
`lib/src/state/ad_event.dart:128`) — nếu 2 provider trả revenue khác đơn vị
tiền tệ ở vùng nào đó, score bị trộn sai đơn vị. Cùng lớp bug với T138
(Arbitrator đa tiền tệ) nhưng ở class khác — nếu implement T136 trước T138,
tiện thể sửa luôn chỗ này (không bắt buộc, ghi chú lại để không quên).

## Việc cần làm

- [ ] Thiết kế "session-alternate exploration" — thêm 1 field
      config mới (opt-in, mặc định tắt) kiểu
      `double explorationSessionRate` (vd 0.05 = 5%) vào chỗ gọi
      `enableWaterfallTuner(...)`/`enableSelfHealingObserver(...)`.
- [ ] Khi bật, MỘT SỐ session (không phải install) của CÙNG 1 thiết bị — dùng
      random cục bộ persist qua session (không phải mỗi session random lại
      từ đầu, tránh liên tục nhảy provider gây trải nghiệm tệ) — thật sự
      `initialize()` với provider THAY THẾ (không phải
      `AdConfig.provider` mặc định) cho session đó, ghi nhận
      `AdLoadEvent`/`AdRevenueEvent` THẬT (không phải shadow request — đây
      là request thật, ads thật hiển thị, chỉ là dùng provider khác thường
      lệ cho ĐÚNG session đó).
- [ ] `WaterfallTuner` giờ tích luỹ được dữ liệu THẬT cho CẢ 2 provider theo
      thời gian (qua nhiều session explore rải rác) — `recommendation`
      giờ có thể thật sự trả về non-null trên 1 install thật.
- [ ] `SelfHealingObserver` giờ có thể thật sự fire
      `AdSelfHealingObserveEvent` khi có đủ dữ liệu — verify lại toàn bộ
      logic `_alreadyObserved` (dedupe) vẫn đúng với luồng dữ liệu mới.
- [ ] Cập nhật doc comment của cả 2 class — xoá đoạn "sẽ nằm im vĩnh viễn",
      thay bằng mô tả cơ chế mới.
- [ ] KHÔNG tự động switch provider cho các session BÌNH THƯỜNG dựa trên
      recommendation — giữ đúng triết lý "chỉ recommend, host tự quyết"
      đã có, trừ phi ticket riêng khác quyết định làm auto-switch (ngoài
      scope ticket này).
- [ ] Test rõ: explore-session KHÔNG được ảnh hưởng VIP member (VIP không
      thấy ads, không có gì để explore), KHÔNG được explore quá thường
      xuyên gây UX tệ (rate thấp, có thể cần cap tần suất tối đa, vd tối đa
      1 explore-session/ngày).

## Ghi chú

Đây là thay đổi kiến trúc thật (từ "1 provider cố định suốt vòng đời
install" sang "thỉnh thoảng 1 session dùng provider khác") — rủi ro cao
nhất là ảnh hưởng trải nghiệm/doanh thu của chính những session bị chọn
explore (dùng provider có thể kém hơn cho session đó, đó là cái giá thật
của A/B đúng nghĩa trên device, không có cách nào tránh hoàn toàn). Cần
`explorationSessionRate` mặc định RẤT thấp và tài liệu rõ trade-off này
trong README trước khi ai bật lên thật. Effort L vì đụng tới luồng
`initialize()`/session lifecycle, không chỉ thêm field.

## Kết quả (2026-09-06) — DONE

- **Status:** ✅ done. **Điểm cuối: 9.5/10** sau **4 vòng review độc lập**
  `codex` (bản copy cô lập): 4/10 → 7/10 → 8/10 → 9.5/10 — đây là task khó
  nhất round này, đụng thật vào session lifecycle như ticket đã cảnh báo.
- **Đã làm cả 3 phần:** `AdManager().pickSessionProvider()` (session-alternate
  exploration, opt-in qua `explorationRate`, rate-limit 1/ngày, không ảnh
  hưởng VIP), `WaterfallTuner`/`SelfHealingObserver` giờ **persist thật qua
  AdPreferences** (không chỉ trong RAM — đây là phần biến "recommendation
  không bao giờ non-null" thành thật khả thi trên 1 device thật), xoá bỏ
  tuyên bố "sits dead forever" khỏi doc comment cả 2 class.
- **Vòng 1 (4/10) — 2 bug BLOCKING:**
  1. `pickSessionProvider()` (khi đó sync) đọc `AdPreferences.instanceOrNull`
     — null lúc cold-start thật (process vừa mở, chưa ai gọi `getInstance()`),
     bypass hoàn toàn rate-limit ngày. Sửa: đổi thành `async`, `await
     AdPreferences.getInstance()` thật.
  2. Reconcile "đã explore" chạy ngay sau `vip.load()` — SỚM hơn GAID
     whitelist import + first-install grace, nên 1 session sau đó mới thật
     sự thành VIP (qua grace) vẫn bị tính nhầm là non-VIP và persist mất 1
     slot explore. Sửa: dời reconcile tới SAU toàn bộ 3 bước VIP-affecting.
  3. (Blocker thứ 3 vòng 1): WaterfallTuner không persist qua session thật
     — implement persist JSON qua AdPreferences.
- **Vòng 2 (7/10) — 3 bug MAJOR:**
  1. **TOCTOU y hệt lớp bug T137 gặp**: guard cũ vẫn còn `await` giữa lúc
     check và lúc apply, khiến 2 refresh chồng lấp có thể ghi đè ngược.
     Riêng T136: reject-path trả `local` (baseline tính lại) thay vì giữ
     nguyên state đang live — tự bắt được TRƯỚC review ngoài nhờ viết test
     trước.
  2. Persist fire-and-forget, không có `ready`/flush contract — sửa bằng
     `Future<void> get ready`, `_writeChain` serialize từng write, `dispose()`
     giờ async chờ write đang chạy (có timeout).
  3. Hydrate không trim về `rollingWindowSize` — sửa bằng lấy N phần tử cuối.
- **Vòng 3 (8/10) — 2 bug MAJOR (tự gây ra khi sửa vòng 2):**
  1. `AdManager.destroy()` gọi `dispose()` KHÔNG await rồi set field `null`
     NGAY — nên `await` phía sau chỉ là `await null` (no-op thật). Sửa:
     capture 2 local TRƯỚC khi null field, await 2 local đó.
  2. Hydrate-vs-first-event race: subscribe stream ngay trong constructor,
     TRƯỚC khi hydrate xong — event thật đến giữa lúc hydrate await có thể
     bị hydrate ghi đè mất. Sửa: `_init()` await hydrate xong mới `.listen()`,
     thêm `_disposed` flag tránh subscribe "ma" nếu dispose() gọi giữa lúc
     hydrate.
  - Khi sửa xong vòng 3, tự chạy full suite bắt được 1 **regression thật do
    chính mình gây ra**: test cũ emit event ngay sau constructor không còn
    được nhận (listener giờ subscribe trễ hơn) — sửa `setUp()` await
    `ready` trước khi emit, đúng theo public contract mới, không phải che
    lỗi bằng delay giả.
- **Baseline cuối:** `flutter analyze` sạch; `flutter test` 1694/1694; 3
  integration test thật trên Pixel 7 Pro pass
  (`t136_session_exploration_test.dart`,
  `t136_waterfall_tuner_persistence_test.dart`, và re-verify
  `t137_periodic_refresh_test.dart` không bị ảnh hưởng).
- API mới: `AdManager.pickSessionProvider()`,
  `WaterfallTuner({persist, rollingWindowSize})` + `.ready`/`.dispose()` giờ
  async, `SelfHealingObserver({persist})` + `.ready`/`.dispose()` giờ async.
  README có section "Session-alternate exploration" ghi rõ trade-off.

## Prompt vòng lặp (dán vào session code mới để bắt đầu implement)

```
Đọc kỹ file doc/task/todo/T136-waterfall-tuner-self-healing-on-device.md
này (nếu đã chuyển sang inprogress/ hoặc done/ thì đọc ở đó). Implement
ĐÚNG scope mô tả trong "Việc cần làm" — KHÔNG thêm scope ngoài mô tả.

SDK này KHÔNG có backend/server riêng — mọi cơ chế cần dữ liệu ngoài phải đi
qua interface host-cung-cấp sẵn có (kiểu RemoteAdSafetyProvider), không tự
dựng server/API mới. Thiết kế "session-alternate exploration" trong ticket
này là 100% on-device, không cần backend — giữ đúng tinh thần đó, đừng đổi
sang hướng cần server dù có vẻ "tiện" hơn.

Viết theo TDD: unit test trước, code sau. Implement xong 1 vòng, chạy đúng
gate đã dùng ở round 40:

"hãy audit lại code changes và chấm điểm trên thang điểm 10 + bổ sung unit
test + widget test + integration test cho mọi case + smoke test lên device
chứng minh. Nếu work và điểm >9/10 thì push code"

Lặp lại: sửa → audit adversarial (có thể dùng codex/agy độc lập trong bản
copy cô lập /tmp, rsync loại trừ build/.dart_tool/Pods/.gradle, KHÔNG cp -R
nguyên khối tránh ENOSPC) → nếu điểm ≤9/10 thì sửa tiếp theo finding →
verify lại → lặp tới khi ≥9/10 mới push. KHÔNG tự ý push nếu chưa đạt
ngưỡng. Di chuyển file ticket này từ todo/ sang inprogress/ khi bắt đầu,
sang done/ khi xong.
```
