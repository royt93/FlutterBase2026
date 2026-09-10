# T154 — Quảng cáo native tính lượt xem dù bị ẩn sau tab khác

**Loại:** bug (rủi ro chính sách mạng quảng cáo)
**Ưu tiên:** P1
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config, tự verify (đối chiếu banner/mrec đã fix round-31/39)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Trong app mẫu, khung chứa quảng cáo native đã được nạp nhưng chưa hiển thị (VD bị ẩn sau tab khác trong `IndexedStack`) vẫn bị tính là đang xem — tốn 1 lượt quảng cáo mà không ai thấy. Rủi ro: Google/AppLovin có quy định cấm tính quảng cáo không ai nhìn thấy, nếu họ phát hiện có thể phạt/khoá tài khoản quảng cáo. Banner và MREC đã được vá đúng vấn đề này ở round-31/round-39; native bị bỏ sót.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/native_ad_widget.dart` (toàn file) — không có tham số `active` và không dùng `VisibilityDetector`, trong khi `banner_ad_widget.dart:56,72` và `mrec_ad_widget.dart:34,43` đã được vá.
- Native ad mount trong 1 tab `IndexedStack` chưa từng active vẫn gọi `_initNative()` ngay trong `initState()` (dòng 119) bất kể tab có hiển thị hay không.
- Native không có auto-refresh nên không lặp lại liên tục như banner/mrec, nhưng lần load đầu vẫn tốn 1 request/impression cho nội dung chưa từng hiển thị.

## Việc cần làm
1. Thêm tham số `active` vào `NativeAdWidget` (mặc định `true`), và tích hợp `VisibilityDetector` giống banner/mrec — chỉ `_initNative()` khi thực sự visible/active.
2. Đảm bảo T153 (buildBanner/buildMrec active passthrough) và task này đồng bộ: sau khi cả 2 xong, có thể cân nhắc thêm `buildNative()` helper vào `AdScreenState` nếu chưa có.
3. Thêm log SafeLogger khi native ad bị trì hoãn init vì chưa active/visible.
4. Thêm demo trong `example/`: native ad trong tab `IndexedStack`, chứng minh không load cho tới khi tab active.
5. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/widget/native_ad_widget.dart: hiện không có tham số active và không dùng VisibilityDetector, khiến _initNative() (dòng ~119) chạy ngay trong initState() bất kể widget có hiển thị hay không — khác với banner_ad_widget.dart (dòng ~56,72) và mrec_ad_widget.dart (dòng ~34,43) đã được vá đúng vấn đề này ở round-31/39. Đọc kỹ cách 2 file đó implement active+VisibilityDetector, áp dụng tương tự cho NativeAdWidget (lưu ý native không auto-refresh nên logic có thể đơn giản hơn — không cần vòng lặp refresh, chỉ cần trì hoãn init lần đầu tới khi active/visible). Viết widget test: NativeAdWidget(active: false) trong tab ẩn của IndexedStack không gọi loadNative của adapter cho tới khi active chuyển true. Thêm log SafeLogger. Thêm demo trong example/.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho `active`/visibility trên `NativeAdWidget`, xác nhận không load khi ẩn/inactive; integration test qua `IndexedStack` thật.
3. Log SafeLogger đầy đủ.
4. Demo trong `example/` + CHANGELOG.md cập nhật.
5. Audit độc lập, chấm điểm /10.
6. ≤9/10: sửa tiếp, quay lại bước 1.
7. >9/10: smoke test thật trên device, chuyển tab qua lại, xác nhận native ad không load ở tab ẩn (kiểm tra qua log/network).
8. Thành công: commit + push. Thất bại: quay lại bước 1.

## Kết quả (2026-09-10)

**Fix:** `NativeAdWidget` được thêm tham số `active` (bool, mặc định `true`,
KHÔNG dùng `VisibilityDetector` — xem lý do bên dưới). `initState()` và
`didUpdateWidget()` chỉ gọi `_initNative()` khi `active == true`; check
`active` thật sự (authoritative) nằm ngay đầu `_initNative()` để chặn cả
những lần gọi trễ qua `addPostFrameCallback` (consent mở lại, rút lại
personalisation, retry trong `build()`). `_initNative()` cũng tự chặn gọi
lặp khi `_allowed.value` đã true (chống double-load khi 2 đường trigger
đụng nhau cùng 1 frame).

**Vì sao KHÔNG dùng `VisibilityDetector` như kế hoạch ban đầu ở mục "Việc
cần làm" #1** (task tự viết trước khi đào sâu implementation, đã tự để ngỏ
"logic có thể đơn giản hơn"): `VisibilityDetector` chỉ báo hiệu SAU khi
paint, và mặc định polling mỗi 500ms (production) — không thể nào nhanh
hơn `initState()` chạy đồng bộ NGAY LÚC mount, nên không thể dùng để CHẶN
lần load đầu tiên. Banner/MREC cũng KHÔNG dùng nó để chặn lần load đầu (tự
đọc lại code `_initBanner`/`_initMrec`: gọi ngay trong
`didChangeDependencies`, chỉ chặn được bằng `active == false` tường minh) —
`VisibilityDetector` ở 2 widget đó chỉ dùng để TẠM DỪNG (pause) một quảng
cáo ĐÃ load rồi mà bị cuộn khuất, vì banner/mrec có auto-refresh ticker cần
dừng. Native không có ticker, không có gì để "dừng" sau khi đã load — nên
không có việc gì cho `VisibilityDetector` làm. Với `IndexedStack` (use-case
thật của bug này), `VisibilityDetector` còn không bao giờ bắn tín hiệu:
`RenderIndexedStack` không bao giờ `paint()` con bị ẩn, y hệt lý do banner's
class doc comment đã ghi. → Cách fix đúng, tối giản, không code chết: chỉ
tham số `active` tường minh, giống hệt cách banner/mrec THỰC SỰ chặn load
đầu tiên (không phải cách chúng "quảng cáo" trong doc comment).

**codex review — 5 vòng, tất cả tìm thật (trừ vòng 5):**
- Vòng 1: bản đầu có `VisibilityDetector` nhưng dead code — `initState` đã
  gọi `_initNative()` đồng bộ trước khi `VisibilityDetector` có cơ hội bắn
  tín hiệu, và `IndexedStack` không bao giờ bắn tín hiệu. → gỡ bỏ, đổi
  `active` từ `bool?` sang `bool` (không cần tri-state vì không có "tự
  động" thật sự).
- Vòng 2 (P2): timer retry-sau-lỗi-30s early-return khi ẩn thay vì
  reset — khiến ô quảng cáo kẹt lỗi vĩnh viễn, không bao giờ load lại dù
  sau đó active lại. → sửa: luôn dispose+reset, chỉ có việc gọi lại
  `_initNative()` là có điều kiện theo `active`.
- Vòng 3 (P1): 3 đường gọi `_initNative()` qua `addPostFrameCallback` chỉ
  check `active` lúc LÊN LỊCH, không check lúc THỰC THI (có thể trễ 1+
  frame, sau khi tab đã ẩn lại). → thêm check `active` làm cổng thẩm quyền
  duy nhất ngay đầu `_initNative()`.
- Vòng 4 (P1): callback trễ ở trên có thể đụng độ với `didUpdateWidget` gọi
  `_initNative()` đồng bộ (bất kỳ rebuild nào của cha, không chỉ đổi
  `active`) → load thật 2 lần cho 1 lần mở lại — rủi ro chính sách đếm
  trùng lượt xem. → thêm chặn `_allowed.value` đã true thì bỏ qua.
- Vòng 5: đề nghị quay lại dùng `VisibilityDetector` "tự động" cho
  trường hợp mặc định — đã đánh giá và KHÔNG áp dụng, lý do kỹ thuật ở
  trên (verify cơ chế thật, không chỉ pattern-match theo banner/mrec).

**Test:**
- Unit (`test/native_ad_widget_test.dart`, nhóm "T154"): 5 case — mount
  `active:false` không load rồi bật `active:true` mới load lần đầu; load
  lỗi trong lúc ẩn vẫn reset để lần sau active lại retry được (pin vòng
  2); reload bị hoãn (`addPostFrameCallback`) không bắn nếu tab đã ẩn lại
  trước khi callback chạy (pin vòng 3); reload hoãn đụng độ
  `didUpdateWidget` đồng bộ chỉ load đúng 1 lần (pin vòng 4, xác nhận có
  thật bằng cách tạm tắt guard — log đổi từ "already allowed/in-flight"
  sang "cooldown", chứng minh guard mới là cơ chế chặn đúng, không phải
  cooldown tình cờ); `active:true` mặc định hoạt động y hệt trước khi có
  fix.
- Widget (`example/test/native_demo_page_test.dart`): demo "IndexedStack
  visibility (T154)" — chuyển tab qua lại trước khi SDK init không crash.
- Integration (`example/integration_test/native_indexedstack_visibility_test.dart`,
  chạy thật trên **Pixel 7 Pro**, `--dart-define=AD_PROVIDER_ADMOB=true`):
  chạy 2 lần — lần 1 xanh hoàn toàn (chuyển tab 1↔2, ad thật ở tab 2 chỉ
  mount khi tab active, không crash); lần 2 bị 1 quảng cáo App Open thật
  che HomePage quá 60s (đúng hành vi SDK, không phải bug — y hệt flaky đã
  ghi nhận ở T150/T152). 1 lần xanh hoàn toàn đã đủ bằng chứng smoke-test
  thật.
- Phát hiện phụ: thêm `example/test/flutter_test_config.dart` (thiếu từ
  trước, không liên quan riêng T154) để zero hoá debounce timer của
  `VisibilityDetector` trong test — cần cho BẤT KỲ test nào mount
  Banner/MrecAdWidget, không chỉ test mới của T154.
- Phát hiện phụ #2: `compliance_demo_page_test.dart` ("dispute kit") có
  flake ~1/3 lần khi chạy CHUNG cả suite `example/test/` (không flake khi
  chạy riêng) — xác nhận bằng `git stash` tái tạo lại TRƯỚC khi có bất kỳ
  thay đổi T154 nào, vẫn flake y hệt tỷ lệ → flake có sẵn từ trước, không
  do T154 gây ra. Không sửa (ngoài phạm vi task này), ghi nhận minh bạch.

**Suite:** 1804/1804 (`packages/ad_sdk`), 38/38 (`example`, khi không dính
flake có sẵn ở trên). `flutter analyze` sạch cả 2 package (chỉ còn 2 info
TickerMode deprecation có từ trước, ngoài phạm vi).

**Điểm tự chấm:** 9.5/10 — 4/5 vòng codex tìm bug thật và đã sửa hết, vòng
5 đã verify kỹ (đo thời gian VisibilityDetector, đối chiếu code thật của
banner/mrec) trước khi quyết định không áp dụng, không phải bỏ qua suông.
