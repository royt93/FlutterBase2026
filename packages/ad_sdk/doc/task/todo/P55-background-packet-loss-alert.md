# P55 — Cảnh báo packet loss định kỳ chạy nền (WorkManager/BGTaskScheduler)

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** agy CLI (audit độc lập)
- **Files:** (mới) — có thể tái dùng `LatencyService`, `NotificationService` hiện có

## Ý tưởng
Ngoài schedule test tốc độ đầy đủ đã có ([[P19-schedule-multi-preset]]), thêm 1 tác vụ nền nhẹ hơn (chỉ đo packet loss/latency, không chạy full stress test tốn pin/data) định kỳ, bắn notification nếu phát hiện bất thường — không cần user mở app.

## Việc cần làm (đề xuất — cần đánh giá chi phí pin/data trước khi code, độ phức tạp cao)
- Đánh giá platform API: `workmanager` (Android) / `BGTaskScheduler` (iOS) — cả 2 đều có giới hạn hệ điều hành riêng (Android Doze, iOS background execution budget), cần research kỹ trước khi cam kết tần suất.
- Thiết kế ngưỡng "bất thường" trước khi code phần notification.

## Acceptance criteria
- [ ] Có kết luận rõ về giới hạn platform (tần suất tối đa khả thi) trước khi implement.
- [ ] Tác vụ nền không làm tăng đáng kể pin/data usage đo được thực tế trên thiết bị.

## Quyết định (2026-08-13)
**Tạm hoãn, chưa implement.** Lý do: yêu cầu thêm dependency native mới (`workmanager`
Android / `BGTaskScheduler` iOS) can thiệp sâu OS — rủi ro bị Apple/Google từ chối khi review
app, tốn pin thêm, và chính acceptance criteria của ticket này bắt buộc phải đo pin/data thật
trên thiết bị thật mới kết luận được có an toàn không. Không có thiết bị thật để đo trong môi
trường hiện tại nên không thể tự tin ship. Đã hỏi ý kiến người dùng (non-tech) — chọn giữ ticket
ở trạng thái `todo`, không code, chờ có điện thoại thật để tự đánh giá pin trước khi quyết định
tiếp.
