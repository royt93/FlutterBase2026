# T61 — README ghi sai default `autoRequestUmpConsent` (false thay vì true)

- **REQ:** audit round mới 2026-08-15 (codex, đã verify độc lập — CONFIRMED)
- **Priority:** P2 · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/README.md:664`

## Vấn đề (Why)
Code default thật là `true` (`ad_config.dart:349`), README bảng cấu hình vẫn ghi `false`. Dev copy block config mẫu từ README/pub.dev có thể vô tình tắt UMP auto-request, gặp zero-ads footgun hoặc flow consent sai kỳ vọng.

## Đã làm (2026-08-15)
Sửa `bool autoRequestUmpConsent = false,` → `true` trong bảng cấu hình mẫu ở README. Đã grep lại toàn README, không còn mention nào khác lệch với code (dòng 139 changelog note và dòng 699/1317 ví dụ đều đã đúng `true` từ trước).

## Acceptance criteria
- [x] README bảng cấu hình khớp default thật trong code.
