# P08 — `TestHistoryStorage.init()` thiếu guard chống double-init

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/test_history_storage.dart`

## Vấn đề
`init()` (dòng 36-78) không có in-flight-future guard, khác `BenchmarkSettingsStorage.init()` và `ScheduleStorage.init()` (đã có). `StressorController`, `HistoryController`, `BenchmarkController` đều gọi `init()` độc lập lúc khởi động app — có race mở Hive box 2 lần cùng lúc nếu các init này overlap.

## Bằng chứng
- `test_history_storage.dart:36-78` — thiếu guard.
- Đối chiếu pattern đúng: `BenchmarkSettingsStorage.init()`, `ScheduleStorage.init()`.

## Đã verify (2026-08-11, audit vòng 2 — subagent đọc source)
Xác nhận lại: `TestHistoryStorage` có cờ `_isInitialized` nhưng đó **không phải in-flight guard** — nếu 2 caller cùng gọi `init()` khi `_isInitialized` vẫn còn `false` (trước khi await Hive mở box xong), cả 2 đều đi qua nhánh mở box, race vẫn xảy ra. Đúng như mô tả ban đầu, chưa fix.

## Việc cần làm (đề xuất, chưa code)
- Thêm in-flight `Future` guard giống 2 storage kia (VD: lưu `Future<void>? _initFuture`, nếu đã có thì return future đó thay vì mở box lần nữa).

## Acceptance criteria
- [ ] Gọi `init()` đồng thời từ nhiều nơi chỉ mở Hive box 1 lần.
- [ ] Unit test: gọi `init()` 2 lần song song (`Future.wait`), verify không throw "box already open" hoặc mở box trùng.
