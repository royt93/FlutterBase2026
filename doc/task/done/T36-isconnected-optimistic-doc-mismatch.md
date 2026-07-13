# T36 — `isConnected` optimistic-by-default: doc T10 mô tả sai hành vi thật

- **REQ:** 2 (work có mạng / không mạng)
- **Priority:** P2 · **Severity:** LOW (doc mismatch, không phải bug chức năng) · **Status:** ✅ done (2026-07-13)
- **Files:** `packages/ad_sdk/lib/src/ad_manager.dart` (dòng ~328, ~1190-1204), `doc/task/done/T10-*.md`

## Vấn đề (Why)
`_lastConnected` seed mặc định là `true` (comment trong code ghi rõ "Seeded true (optimistic)... deliberate" — broken detector không nên chặn ads vĩnh viễn). Khi `ConnectionNotifierTools` throw exception hoặc chưa có event connectivity nào bắn (cold-start), SDK coi là **có mạng**. Đây là hành vi **có chủ đích, hợp lý**, nhưng mô tả của task T10 gốc ("pessimistic fast-retry") không khớp — gây hiểu nhầm ở các lần audit sau (tưởng đây là bug còn sót).

## Giải pháp đề xuất
Không cần đổi code (hành vi optimistic-by-default là quyết định đúng, tránh false-negative khi connectivity plugin lỗi). Chỉ cần:
- Sửa lại nội dung T10 trong `doc/task/done/T10-*.md` cho khớp hành vi thật, hoặc thêm addendum.
- Thêm 1 dòng note trong code comment trỏ tới quyết định này để audit sau không báo nhầm lại.

## Acceptance criteria
- [x] `doc/task/done/T10-*.md` mô tả đúng: optimistic-by-default là chủ đích, kèm lý do.
- [x] Không có thay đổi hành vi runtime (chỉ sửa tài liệu).

## Kết quả
Sửa dòng mô tả trong `doc/task/done/T10-isconnected-pessimistic-fastretry.md` (checkbox cũ ghi "default false pessimistic") thành mô tả đúng hành vi thật: fallback về `_lastConnected` (seed `true`, optimistic), trỏ tới phần "Kết quả & quyết định" đã có sẵn trong file đó. Không đổi code, không đổi runtime behavior.

## Giới hạn đã biết
Đây thuần là sửa tài liệu — không có test tự động cho việc mô tả đúng hay sai. Rủi ro duy nhất là audit tương lai đọc lại và vẫn hiểu nhầm nếu không đọc kỹ phần "Kết quả & quyết định" đã dẫn chiếu.
