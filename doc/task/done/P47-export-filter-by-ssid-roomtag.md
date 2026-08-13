# P47 — Lọc export CSV/PDF/JSON theo SSID/room tag trước khi xuất

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/history_controller.dart:316` (hạ tầng export hiện có)

## Ý tưởng
Hiện export luôn xuất toàn bộ (hoặc theo khoảng ngày) — chưa cho user chọn lọc theo SSID cụ thể hoặc room tag cụ thể trước khi export. Hữu ích khi user chỉ muốn báo cáo về 1 mạng/1 phòng cụ thể.

## Việc cần làm (đề xuất, chưa code)
- Thêm UI chọn filter SSID/roomTag trước khi bấm export, truyền filter vào hàm generate CSV/PDF/JSON hiện có.

## Acceptance criteria
- [ ] Chọn 1 SSID/room tag cụ thể → file export chỉ chứa test khớp filter.
