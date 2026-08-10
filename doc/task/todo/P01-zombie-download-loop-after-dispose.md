# P01 — Zombie download loop sau khi dispose `StressorController`

- **Priority:** P0 · **Severity:** CRITICAL · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source (đọc trực tiếp toàn bộ file, verify từng dòng)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/stressor_controller.dart`

## Vấn đề
`onClose()` (dòng 242-273): khi controller bị dispose lúc test đang chạy, code lưu kết quả rồi defer `_cleanup()` 100ms bằng `Future.delayed`, nhưng **không set `isRunning.value = false`**. Trong khi đó `_runDownloadLoop` (dòng 798) chạy `while (isRunning.value) { ... }`. `_cleanup()` (dòng 286) đóng `dio` — sau đó mỗi lần loop gọi `dio.get()` sẽ throw, bị catch, rồi retry lại sau ~100ms, lặp vô hạn. Đây là leak thật (task/timer chạy mãi trong background), không phải lý thuyết.

## Bằng chứng
- `stressor_controller.dart:242-273` — `onClose()`, thiếu `isRunning.value = false`.
- `stressor_controller.dart:351,514` — 2 nơi duy nhất set `isRunning`, đều không nằm trong `onClose`.
- `stressor_controller.dart:798` — `while (isRunning.value)` trong `_runDownloadLoop`.
- `stressor_controller.dart:286` — `_cleanup()` đóng `dio`.

## Việc cần làm (đề xuất, chưa code)
- Set `isRunning.value = false` ngay đầu `onClose()` trước khi defer `_cleanup()`, để `_runDownloadLoop`'s `while` thoát ngay ở lần check tiếp theo, không cần đợi `dio` bị đóng rồi throw.
- Xem xét bỏ hẳn `Future.delayed(100ms)` nếu không còn cần thiết sau khi `isRunning=false` đã chặn loop.

## Acceptance criteria
- [ ] `onClose()` set `isRunning.value = false` trước khi cleanup.
- [ ] Test: mở stressor, bắt đầu test, pop screen giữa lúc đang chạy, verify không còn network call nào phát ra sau khi controller dispose (mock Dio, assert `dio.get` không gọi thêm sau X ms).
- [ ] `flutter analyze` sạch, test cũ không regress.
