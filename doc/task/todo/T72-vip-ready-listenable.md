# T72 — Expose `ValueListenable` cho trạng thái `AdManager().vip` sẵn sàng

- **REQ:** audit round mới 2026-08-15 (agy)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart:107,242`

## Vấn đề (Why)
`AdManager().vip` trả `null` cho tới khi `initialize()` xong. Nếu screen render trước khi SDK init xong, dev không có cách nghe thời điểm `vip` sẵn sàng ngoài tự poll `initRevision`.

## Đề xuất
Thêm `AdManager().vipReadyNotifier` (hoặc tương tự) — `ValueListenable<bool>` báo khi `vip` đã sẵn sàng, DX rõ ràng hơn polling thủ công.

## Acceptance criteria
- [ ] `vipReadyNotifier` (hoặc tên tương đương) fire đúng 1 lần khi `vip` chuyển từ null → sẵn sàng.
- [ ] README cập nhật ví dụ dùng.
