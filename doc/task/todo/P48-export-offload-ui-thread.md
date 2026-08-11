# P48 — Đưa tính toán export nặng ra khỏi UI thread (`compute()`/Isolate)

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/history_controller.dart` (generate CSV/PDF)

## Vấn đề / cơ hội
Generate CSV/PDF hiện chạy đồng bộ trên main thread (UI thread) trong `HistoryController`. Với lịch sử lớn (gần giới hạn 100 item của `TestHistoryStorage`) và PDF có chart/nhiều trang, có thể gây giật UI trong lúc export.

## Việc cần làm (đề xuất, chưa code)
- Đo thực tế thời gian generate PDF/CSV với 100 item trước khi quyết định có cần `compute()`/Isolate hay không — có thể không đáng làm nếu thời gian đã đủ nhanh (<100ms).
- Nếu cần: đưa hàm generate (pure, không đụng GetX state) vào `compute()`.

## Acceptance criteria
- [ ] Có số đo thực tế (ms) trước/sau khi quyết định.
- [ ] Nếu áp dụng `compute()`: export 100 item không làm UI giật (frame drop) khi quan sát bằng DevTools.
