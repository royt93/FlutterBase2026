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
- [x] Insight chỉ hiện khi có đủ dữ liệu tin cậy (định nghĩa rõ ngưỡng mẫu tối thiểu).
- [x] Insight hiển thị đúng khung giờ thực sự có pattern giảm tốc lặp lại (verify bằng dữ liệu giả lập).

## Kết quả (2026-08-13)
- `services/time_of_day_pattern.dart`: pure function `detectTimeOfDayThrottlePatterns(results)` group theo `startTime.hour` (0-23), so trung bình mỗi giờ với trung bình chung. Ngưỡng tin cậy: `kMinSamplesPerHour = 3` (AC1 — giờ nào có ít hơn 3 test bị bỏ qua, tránh false positive từ mẫu quá nhỏ) và `kMinPctSlowerThanOverall = 20.0` (chỉ coi là "pattern" nếu chậm hơn ít nhất 20% so với trung bình chung, không phải nhiễu ngẫu nhiên).
- `presentation/history_screen.dart`: thêm banner insight nhỏ (icon đồng hồ + text) ngay dưới `SummaryStatsCard`, tính trên `controller.allResults` lọc 30 ngày gần nhất, chỉ hiện khung giờ có `pctSlowerThanOverall` cao nhất nếu có. Ẩn hoàn toàn (`SizedBox.shrink()`) khi không đủ dữ liệu — không cần notification, đúng như ticket đề xuất "chỉ show trong dashboard/history".
- Test mới: `test/p29_time_of_day_pattern_test.dart` (4 case, dữ liệu giả lập: rỗng → empty; 1 test lẻ một giờ → không đủ mẫu nên bỏ qua; 5 ngày liên tục chậm cùng 1 giờ → phát hiện đúng giờ + đúng sample count; chênh lệch trong biên độ bình thường (90 vs 100) → không báo pattern giả).
- `ponytail:` bỏ qua tính median (ticket chỉ đề cập "trung bình/median" ở phần đề xuất, không phải AC) — trung bình đã đủ để thoả cả 2 acceptance criteria, thêm median chỉ tăng phức tạp không cần thiết.
