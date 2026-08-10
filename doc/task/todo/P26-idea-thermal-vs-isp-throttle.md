# P26 — Idea: phân biệt throttle do ISP vs máy nóng (thermal)

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI + agy CLI (Epic D) — cùng ý tưởng cũng được Epic E đề xuất nâng thành flagship feature, xem `doc/task/BACKLOG-product-2026-08-10.md` phần Epic E.
- **Files:** `lib/mckimquyen/widget/wifi_stressor/models/test_result.dart:36` (field `thermalStatus` đã có sẵn), `stressor_controller.dart:469`

## Ý tưởng
`TestResult.thermalStatus` đã được lưu sẵn mỗi lần test. Correlate `thermalStatus` với `avgSpeed` theo thời gian trong 1 lần test / qua lịch sử để phân biệt "mạng chậm do ISP" khỏi "máy nóng làm CPU throttle ảnh hưởng radio/xử lý".

## Việc cần làm (đề xuất, chưa code)
- Bản nhỏ (idea-tier): hiển thị cảnh báo đơn giản "thiết bị đang nóng, tốc độ đo có thể không chính xác" khi `thermalStatus` ở mức cao trong lúc test.
- Bản lớn (flagship-tier, xem P30-P33): xây hẳn tính năng "Thermal-Aware Speed Testing" độc lập, phân tích correlate qua lịch sử Hive nhiều lần test — quyết định scope này khi ưu tiên vào backlog.

## Acceptance criteria
- [ ] (Bản nhỏ) Cảnh báo hiển thị đúng khi thiết bị nóng trong lúc test.
- [ ] (Nếu chọn bản lớn) Xem acceptance criteria mở rộng khi task này được nâng cấp — cần thiết kế riêng.
