# T70 — `AdEventLog` ghi SharedPreferences ở mỗi sự kiện đơn lẻ, nên debounce/batch

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/compliance/ad_event_log.dart:88-97`

## Vấn đề (Why)
`jsonEncode` danh sách tới 5,000 phần tử + `setString` xuống `SharedPreferences` ở MỖI sự kiện ad (load/show/click/impression/revenue/signal). App tần suất sự kiện cao gây tốn CPU/nghẽn disk I/O trên main isolate.

## Đề xuất
Gom nhóm ghi sau 1-2 giây hoặc khi app chuyển background, thay vì ghi ngay mỗi event.

## Acceptance criteria
- [ ] Nhiều event liên tiếp trong <1s chỉ trigger 1 lần ghi disk (hoặc ghi khi background).
- [ ] Không mất event nào nếu app bị kill giữa lúc debounce đang chờ (flush khi lifecycle paused).
- [ ] `flutter test` pass.
