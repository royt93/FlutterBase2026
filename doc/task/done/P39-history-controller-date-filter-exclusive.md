# P39 — Tab Day/Week/Month trong History loại bỏ test đúng ranh giới đầu (exclusive)

- **Priority:** P3 · **Severity:** LOW · **Status:** ✅ done (2026-08-11)
- **Nguồn:** **[đồng thuận]** codex CLI + subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/history_controller.dart:124-149` (`_applyTimeRangeFilter`)

## Vấn đề
Cùng loại bug với [[P05-history-date-range-boundary-exclusive]] nhưng ở **file/hàm khác** (đây là filter UI-level cho tab Day/Week/Month trong History screen, không phải storage-level export theo khoảng ngày tuỳ chọn): cả 3 case `'day'` (dòng 129,131), `'week'` (135,137), `'month'` (141,143) dùng `result.startTime.isAfter(startDate)` — exclusive. Test chạy đúng lúc 00:00:00 hôm nay (mốc `startDate` của tab Day) bị loại khỏi tab Day.

## Bằng chứng
- `history_controller.dart:129,131` (day), `:135,137` (week), `:141,143` (month).

## Việc cần làm (đề xuất, chưa code)
- Đổi `isAfter(startDate)` → `!isBefore(startDate)` (inclusive) ở cả 3 case.
- Sửa cùng lúc với P05 nếu convenient (cùng class bug, khác file), nhưng đây là 2 ticket riêng vì code path độc lập.

## Acceptance criteria
- [x] Test với `startTime` đúng bằng mốc bắt đầu của tab (00:00:00 hôm nay/7 ngày trước/30 ngày trước) xuất hiện đúng trong tab tương ứng.
- [x] Unit test cover boundary cho cả 3 case.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp 1 helper dùng chung, sửa cả 2 nơi (đây + [[P05-history-date-range-boundary-exclusive]]) trong 1 PR — không tách riêng như đề xuất ban đầu ở trên.

## Kết quả (2026-08-11)
`_applyTimeRangeFilter()` cả 3 case ('day'/'week'/'month') đổi `isAfter` → `isOnOrAfter` (extension dùng chung với P05). Test boundary: `test/date_time_ext_test.dart` (test đơn vị cho extension; widget test cho chính `HistoryController` để lại cho P46 — coverage rộng hơn của screen này).
