# T70 — `AdEventLog` ghi SharedPreferences ở mỗi sự kiện đơn lẻ, nên debounce/batch

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/compliance/ad_event_log.dart:88-97`

## Vấn đề (Why)
`jsonEncode` danh sách tới 5,000 phần tử + `setString` xuống `SharedPreferences` ở MỖI sự kiện ad (load/show/click/impression/revenue/signal). App tần suất sự kiện cao gây tốn CPU/nghẽn disk I/O trên main isolate.

## Đề xuất
Gom nhóm ghi sau 1-2 giây hoặc khi app chuyển background, thay vì ghi ngay mỗi event.

## Acceptance criteria
- [x] Nhiều event liên tiếp trong <1s chỉ trigger 1 lần ghi disk (hoặc ghi khi background).
- [x] Không mất event nào nếu app bị kill giữa lúc debounce đang chờ (flush khi lifecycle paused).
- [x] `flutter test` pass.

## Đã làm (2026-08-16)
`AdEventLog._append()` giờ dùng `Timer` debounce 1s (reset mỗi event mới) thay vì gọi `_schedulePersist()` ngay lập tức. Thêm `flush()` — cancel timer đang chờ + ghi ngay + await chain, dùng khi có nguy cơ process bị kill. Wire `flush()` vào `AdManager.didChangeAppLifecycleState`'s nhánh `paused`.

**Bug phụ phát hiện qua TDD (root cause thật, không phải né tránh):** `AdManager.destroy()` KHÔNG BAO GIỜ reset `_eventLog` về null (khác với `_vipManager`/`_consentManager`/`_arbitrator`/`_fillRateMonitor` đều được dispose+null rõ ràng, có comment giải thích lý do). Vì `_eventLog` sống sót qua các chu kỳ destroy→re-init, thêm `flush()` mới vào nhánh `paused` khiến MỌI test khác trong cùng process gọi `didChangeAppLifecycleState(paused)` sau khi có 1 real-init từng chạy cũng vô tình kích hoạt ghi đĩa bất ngờ — gây flaky test ngẫu nhiên (test khác nhau fail mỗi lần chạy). Fix root cause: `destroy()` giờ cũng `flush()` rồi null `_eventLog`, đúng pattern các subsystem khác.

TDD: `ad_event_log_test.dart` thêm group `debounced persist (T70)` dùng `fakeAsync` (đã có sẵn trong dev_dependencies) để test coalescing không cần chờ thật 1s. 3 test cũ dựa vào `Future.delayed(Duration.zero/50ms)` đổi sang gọi `flush()` tường minh (chính xác hơn, không phụ thuộc timing thật). Thêm test wiring ở `ad_manager_core_test.dart` (seam mới `debugEventLog`) xác nhận `paused` flush đúng entry đang debounce — dùng marker string thay vì check `isNull` tuyệt đối, vì `AdPreferences` là singleton dùng chung xuyên suốt cả file test khổng lồ này.

`flutter test`: 729/729 pass (chạy lặp lại 2 lần xác nhận hết flaky), `flutter analyze` sạch.
