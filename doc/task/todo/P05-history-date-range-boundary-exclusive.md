# P05 — Khoảng ngày history/export loại bỏ test đúng ranh giới đầu/cuối

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI + subagent đọc source (2 nguồn độc lập cùng chỉ ra đúng 1 vị trí)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/test_history_storage.dart`

## Vấn đề
`getResultsByDateRange` (dòng 162-164) dùng `isAfter(start)`/`isBefore(end)` — cả 2 đều exclusive, nên test có timestamp đúng bằng `start` hoặc `end` (VD: test chạy đúng 00:00:00 của ngày bắt đầu) bị loại khỏi kết quả. Ảnh hưởng tới report/ISP dispute export theo khoảng ngày.

## Bằng chứng
- `test_history_storage.dart:162-164`.

## Bổ sung (2026-08-11, audit vòng 2 — codex CLI)
Bug **cùng loại nhưng ở file khác**: `HistoryController._applyTimeRangeFilter()` (`controllers/history_controller.dart:129,131,135-143`) filter tab Day/Week/Month trên UI cũng dùng `isAfter(startDate)` exclusive — độc lập với storage-level bug này. Xem [[P39-history-controller-date-filter-exclusive]] (ticket riêng, file khác nên không gộp).

## Việc cần làm (đề xuất, chưa code)
- Đổi thành inclusive: `!isBefore(start) && !isAfter(end)` (hoặc `isAfterOrEqual`/`isBeforeOrEqual` tương đương).

## Acceptance criteria
- [ ] Test với timestamp đúng bằng `start`/`end` được include trong kết quả.
- [ ] Unit test cover trường hợp boundary chính xác.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp 1 helper dùng chung (VD `DateTimeRangeX.containsInclusive`), sửa cả 2 nơi (đây + [[P39-history-controller-date-filter-exclusive]]) trong 1 PR — dù khác file/code path, cùng 1 class bug nên tránh vá lặp logic inclusive-boundary ở 2 chỗ riêng.
