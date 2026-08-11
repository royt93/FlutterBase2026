# P04 — CSV export không escape field

- **Priority:** P1 · **Severity:** HIGH · **Status:** 🔲 todo
- **Nguồn:** codex CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/history_controller.dart`

## Vấn đề
Dòng 499-519 build CSV bằng cách nối string trực tiếp, không escape. SSID, room tag, hoặc field text nào chứa dấu phẩy/newline sẽ làm vỡ định dạng CSV (lệch cột, dòng bị cắt ngang).

## Bằng chứng
- `history_controller.dart:499-519`.

## Bổ sung (2026-08-11, audit vòng 2 — claude CLI)
Ngoài lỗi format, còn rủi ro **formula injection**: nếu field text (SSID, room tag) bắt đầu bằng `=`, `+`, `-`, `@`, Excel/Sheets có thể diễn giải thành công thức khi mở file (CWE-1236). Khi thêm hàm escape CSV, cần thêm bước tiền tố `'` (single-quote) cho field bắt đầu bằng các ký tự trên, không chỉ escape dấu phẩy/newline.

## Việc cần làm (đề xuất, chưa code)
- Thêm hàm escape CSV chuẩn (bọc field có chứa `,`/`"`/newline trong dấu ngoặc kép, double-quote ký tự `"` bên trong) trước khi join, áp dụng cho mọi field text (SSID, roomTag, status...).

## Acceptance criteria
- [ ] SSID/room tag chứa dấu phẩy hoặc newline export ra CSV vẫn mở đúng cột trong Excel/Sheets.
- [ ] Unit test: room tag `"Phòng, khách"` hoặc chứa `\n` → CSV parse lại ra đúng giá trị gốc.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp 1 PR sửa cả escape (ticket này) và thêm cột `roomTag`/`thermalStatus` ([[P36-export-missing-roomtag-thermalstatus]]) — cùng đụng `history_controller.dart` phần export, tránh review/merge 2 lần trên cùng đoạn code.
