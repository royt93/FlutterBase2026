# P17 — Ghép Room Comparison + Heatmap thành lưới phòng × thời gian

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI + claude CLI + subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/room_comparison_screen.dart`, `heatmap_screen.dart`, `models/test_result.dart` (field `roomTag`)

## Vấn đề / cơ hội
`room_comparison_screen.dart` đã có `roomTag` (dòng liên quan tới `test_result.dart:18`), `heatmap_screen.dart` đã có time-axis heatmap — nhưng đây là 2 màn hình tách biệt. Ghép thành 1 lưới **phòng (hàng) × thời gian (cột)** sẽ cho thấy phòng nào yếu ở khung giờ nào, thông tin mà 2 màn riêng lẻ không thể hiện được.

## Việc cần làm (đề xuất, chưa code)
- Thiết kế UI mới: hàng = room tag, cột = time bucket (giống cấu trúc `heatmap_screen.dart` hiện tại nhưng group theo room trước).
- Xử lý case chưa gắn `roomTag` cho test cũ — xem P24 (retro-tag) làm tiền đề, hoặc hiển thị nhóm "Chưa gắn phòng" riêng.
- Cân nhắc đây có thể là 1 tab/mode mới trong `heatmap_screen.dart` hoặc `room_comparison_screen.dart` thay vì tạo screen thứ 3 hoàn toàn mới (đỡ tăng số lượng entry point).

## Acceptance criteria
- [ ] Xem được lưới phòng × thời gian với màu sắc theo tốc độ, tương tự tinh thần heatmap hiện tại.
- [ ] Test có `roomTag` và test chưa gắn được xử lý rõ ràng, không mất dữ liệu khỏi view.
