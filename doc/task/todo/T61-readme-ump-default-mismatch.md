# T61 — README ghi sai default `autoRequestUmpConsent` (false thay vì true)

- **REQ:** audit round mới 2026-08-15 (codex, đã verify độc lập — CONFIRMED)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/README.md:660,664`, `packages/ad_sdk/lib/src/config/ad_config.dart:349`

## Vấn đề (Why)
Code default thật là `true` (`ad_config.dart:349`), README bảng cấu hình vẫn ghi `false`. Dev copy block config mẫu từ README/pub.dev có thể vô tình tắt UMP auto-request, gặp zero-ads footgun hoặc flow consent sai kỳ vọng.

## Đề xuất
Sửa README khớp code. Optional: thêm 1 dòng note nhắc kiểm tra README mỗi lần đổi default trong `ad_config.dart` để tránh drift lặp lại.

## Acceptance criteria
- [ ] README bảng cấu hình khớp default thật trong code.
