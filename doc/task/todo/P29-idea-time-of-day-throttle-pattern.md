# P29 — Idea: phát hiện pattern nghẽn theo khung giờ từ heatmap history

- **Priority:** P3 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** claude CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/services/test_history_storage.dart` (Hive `test_history`)

## Ý tưởng
Dữ liệu lịch sử test (Hive `test_history`, đã được dùng làm heatmap) đủ để tự động phân tích và cảnh báo "tốc độ giảm đều đặn vào khung giờ X" (VD giờ cao điểm buổi tối) — chỉ cần thêm bước phân tích, không cần thêm hạ tầng đo mới.

## Việc cần làm (đề xuất, chưa code)
- Viết hàm phân tích group test theo giờ-trong-ngày, tính trung bình/median tốc độ mỗi khung giờ qua N ngày gần nhất.
- Nếu phát hiện khung giờ nào tụt rõ rệt và lặp lại nhiều ngày → hiển thị insight (không cần notification, có thể chỉ show trong dashboard/history).
- Cần đủ dữ liệu lịch sử (tối thiểu bao nhiêu test/ngày) mới đưa ra kết luận — tránh false positive từ mẫu quá nhỏ.

## Acceptance criteria
- [ ] Insight chỉ hiện khi có đủ dữ liệu tin cậy (định nghĩa rõ ngưỡng mẫu tối thiểu).
- [ ] Insight hiển thị đúng khung giờ thực sự có pattern giảm tốc lặp lại (verify bằng dữ liệu giả lập).
