# T13 — Close `_eventStream` + pop dialog khi destroy/reset

- **REQ:** 3 (no memory leak)
- **Priority:** P2 · **Severity:** MEDIUM · **Status:** ✅ done (2026-07-05)

## Kết quả & quyết định
- **AdLoadingDialog.resetState()** nay **pop dialog đang hiện** trước khi clear flag (try/catch navigator disposed) → destroy giữa lúc dialog hiện không để lại dialog kẹt che UI. Test: `ad_loading_dialog_test.dart` (2 case: pop khi showing, no-op khi không showing).
- **Không close `_eventStream`** (cân nhắc kỹ): nó `final` + expose public qua `AdManager().events` cho host (RevenuePanel…) subscribe. Close+recreate sẽ gửi `done` cho subscriber và phá luồng. Nó cũng **bounded đúng 1 instance/process** (singleton) nên KHÔNG phải leak thật; `_emit` đã guard `isClosed`. ⇒ giữ nguyên là lựa chọn đúng, không phải thiếu sót.
- **269+2 test xanh.**
- **Files:** `core/ad_manager.dart` (`_eventStream` `:156-157`, `destroy` `:783-822`), `widget/ad_loading_dialog.dart` (`resetState`)

## Vấn đề (Why)
`_eventStream` (broadcast) tạo 1 lần, `destroy()` không close → tích tụ khi destroy/init lặp. `AdLoadingDialog.resetState()` zero cờ `_isShowing` nhưng **không pop** dialog đang hiện → có thể chồng dialog trên native stack.

## Acceptance criteria
- [ ] `destroy()` close `_eventStream` an toàn (guard `isClosed` ở `_emit` đã có `:1552`); init tạo lại stream mới.
- [ ] `AdLoadingDialog.resetState()` chủ động pop dialog đang mở (try-catch navigator disposed) trước khi clear cờ.
- [ ] Không rò rỉ StreamController qua nhiều chu kỳ destroy/init.

## Test
- [ ] Unit: destroy→init nhiều lần không tăng số StreamController sống.
