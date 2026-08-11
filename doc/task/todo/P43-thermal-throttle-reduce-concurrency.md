# P43 — Tự giảm số connection song song khi máy nóng (thermal throttle)

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/stressor_controller.dart` (đọc `thermalStatus`), test detail hiện đã cảnh báo thermal (`presentation/test_detail_screen.dart:53-56`)

## Ý tưởng
App đã đọc và lưu `thermalStatus` trong `TestResult` nhưng chưa dùng nó để **chủ động điều chỉnh** hành vi stress test — chỉ hiển thị cảnh báo sau khi test xong. Khi `thermalStatus` ở mức nghiêm trọng trong lúc đang test, tự động giảm số connection song song (giảm tải CPU/nhiệt) thay vì tiếp tục full tải, giúp kết quả đo phản ánh đúng mạng hơn là bị nhiễu bởi máy nóng.

## Việc cần làm (đề xuất — cần thiết kế ngưỡng trước khi code)
- Đọc `thermalStatus` trong lúc `_runDownloadLoop` đang chạy (không chỉ lúc lưu kết quả cuối), giảm `maxConcurrent` khi vượt ngưỡng.
- Quyết định ngưỡng cụ thể và mức giảm (cần test thực tế trên thiết bị, không đoán số).

## Acceptance criteria
- [ ] Có ngưỡng thermal cụ thể được quyết định và ghi lại lý do chọn.
- [ ] Test trên thiết bị nóng thật (hoặc mock `thermalStatus`) verify concurrency giảm đúng.
