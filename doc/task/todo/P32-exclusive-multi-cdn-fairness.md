# P32 — Tính năng độc quyền: Multi-CDN Fairness Score

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI + agy CLI
- **Files liên quan (đã có sẵn):** `stressor_controller.dart:151,188` (`selectedServers`, failed URL tracking)

## Ý tưởng
Test song song nhiều CDN khác nhau (Cloudflare, Fast.com, GitHub, Linode, Vultr...) cùng lúc thay vì 1 CDN tại 1 thời điểm, để phân biệt "ISP nghẽn backhaul chung" (mọi CDN đều chậm) khỏi "1 CDN cụ thể đang bị throttle riêng" (chỉ 1 CDN chậm, còn lại bình thường) — thông tin mà speed-test đơn-endpoint không thể cho biết.

## Việc cần làm (đề xuất — cần thiết kế trước khi code)
- Đánh giá tải thiết bị/băng thông khi chạy song song nhiều CDN cùng lúc (có thể cần giới hạn số CDN đồng thời để không làm sai lệch kết quả do nghẽn cổng WiFi của chính máy).
- Thiết kế UI hiển thị kết quả so sánh giữa các CDN (bar chart hoặc bảng), tính "fairness score" (độ lệch chuẩn giữa các CDN — lệch cao = có CDN bị throttle riêng).
- Tái dùng `selectedServers`/failed-URL tracking đã có sẵn trong `stressor_controller.dart`.

## Acceptance criteria
- [ ] Có kết luận rõ về giới hạn kỹ thuật (số CDN chạy song song tối đa hợp lý) trước khi implement.
- [ ] Score/kết quả phân biệt được rõ case "mọi CDN đều chậm" vs "chỉ 1 CDN chậm" qua dữ liệu test thật.
