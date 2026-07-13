# T31 — `_eventStream` không được close() trong `destroy()`

- **REQ:** 3 (vòng đời, no memory leak)
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** ✅ done (2026-07-13)
- **Files:** `packages/ad_sdk/lib/src/ad_manager.dart` (`_eventStream`, `destroy()`, `_emit()`)

## Vấn đề (Why)
T13 được đánh dấu done nhưng verify tươi 2026-07-13 cho thấy `destroy()` **không hề gọi** `_eventStream.close()`. Guard `if (_eventStream.isClosed) return;` trong `_emit()` hiện là dead code vì không có nơi nào set nó thành closed. Mỗi chu kỳ `destroy() → initialize()` lặp lại (hot-restart nhiều lần, test suite gọi nhiều lần, hoặc kịch bản multi-init) sẽ rò rỉ 1 `StreamController` + toàn bộ subscriber còn treo trên nó.

## Giải pháp đề xuất
- Gọi `_eventStream.close()` thật trong `destroy()`.
- Vì `AdManager` có thể `initialize()` lại sau `destroy()` (không phải one-shot), cần tạo lại `StreamController.broadcast()` mới ở đầu `initialize()` (hoặc lazy-recreate trong getter `events`) thay vì coi `_eventStream` là `final` khởi tạo 1 lần duy nhất.
- Kiểm tra toàn bộ nơi subscribe `AdManager().events` (host + example) không bị vỡ khi stream cũ đóng và thay bằng instance mới.

## Acceptance criteria
- [ ] `destroy()` gọi `_eventStream.close()` thật.
- [ ] `initialize()` sau `destroy()` cho phép subscribe lại `events` bình thường (không throw "Cannot add event after closing").
- [ ] Test regression: init → destroy → init lặp N lần, assert không leak `StreamController` (dùng `StreamController.hasListener`/instance count hoặc theo dõi qua fake listener).

## Test đề xuất
Thêm case vào `banner_leak_regression_test.dart` hoặc file mới `event_stream_lifecycle_test.dart`: init/destroy 10+ vòng, mỗi vòng subscribe `events`, assert không có exception "add after close" và listener cũ thực sự bị gỡ.

## Kết quả
`destroy()` gọi `_eventStream.close()` rồi tái tạo `StreamController.broadcast()` mới ngay sau đó (`_eventStream` bỏ `final`). Test mới trong `test/ad_manager_core_test.dart` (`group('destroy() event stream lifecycle (T31)')`) xác nhận: subscriber cũ nhận `onDone` khi `destroy()` chạy, và `debugEmit()` sau `destroy()` không throw (chứng minh controller mới đã sẵn sàng nhận event cho chu kỳ `initialize()` kế tiếp). `flutter analyze` + `flutter test` sạch trong `packages/ad_sdk`.

## Giới hạn đã biết
Không có cơ chế đếm/giới hạn số lần init↔destroy lặp lại trong 1 session — nếu có leak ở tầng khác (không phải `_eventStream`) thì test này không phát hiện được, vì nó chỉ verify đúng vòng đời của riêng stream này.
