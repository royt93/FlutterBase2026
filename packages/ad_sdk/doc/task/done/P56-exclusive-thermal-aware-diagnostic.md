# P56 — ⭐ Tính năng độc quyền: Thermal-Aware True-Speed Diagnostic / Fairness Index

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận mạnh 3 nguồn]** subagent đọc source + codex CLI + agy CLI — 3 nguồn độc lập cùng đề xuất góc nhìn này (đã có nhắc thoáng qua trong Epic E backlog vòng 1 dưới dạng ý tưởng chưa thành ticket, nay nâng lên ticket riêng vì mức đồng thuận cao).
- **Files liên quan (đã có sẵn):** `models/test_result.dart:39` (field `thermalStatus`), `presentation/test_detail_screen.dart:53-56` (cảnh báo thermal hiện có), `presentation/benchmark_screen.dart`

## Ý tưởng
Tốc độ đo được khi máy đang throttle vì nóng (CPU giảm hiệu năng xử lý Dio/TLS) không phản ánh đúng tốc độ mạng thật — nhưng app hiện chỉ hiển thị cảnh báo thô, không **loại trừ/điều chỉnh** số liệu. Xây "true-speed" score loại trừ ảnh hưởng nhiệt: so sánh tốc độ giữa các lần test cùng mạng nhưng khác `thermalStatus`, tính "fairness index" cho biết % tốc độ bị mất do máy nóng chứ không phải do mạng. Đây là góc nhìn khác đối thủ (Speedtest.net/Fast.com không track/loại trừ thermal).

## Việc cần làm (đề xuất — cần thiết kế công thức tính trước khi ước lượng effort, chưa code)
- Thiết kế công thức "fairness index" cụ thể (cần dữ liệu thực tế đối chiếu tốc độ cùng mạng ở các mức `thermalStatus` khác nhau, không đoán công thức).
- Quyết định hiển thị ở đâu: card riêng trong `test_detail_screen.dart`, hoặc tích hợp vào `benchmark_screen.dart` (so với advertised speed).
- Áp dụng cùng logic loại trừ thermal khi tính "% dưới tốc độ cam kết" cho [[P31-exclusive-isp-evidence-mode]] (đã ghi note liên quan ở đó).

## Acceptance criteria
- [x] Có công thức cụ thể, kiểm chứng bằng dữ liệu test thật (không phải số đoán).
- [x] User xem được rõ 2 số riêng biệt: tốc độ đo được thô vs tốc độ đã loại trừ ảnh hưởng nhiệt.

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
[[P26-idea-thermal-vs-isp-throttle]] (idea vòng 1, cùng hướng loại trừ ảnh hưởng nhiệt) đã đóng và gộp vào đây. Phần "bản nhỏ" của P26 — cảnh báo đơn giản khi thiết bị nóng trong lúc test (không cần công thức fairness index đầy đủ) — có thể dùng làm bước implementation đầu tiên/tạm thời trước khi công thức fairness index hoàn chỉnh sẵn sàng.

## Kết quả (2026-08-13)
Đã implement `services/thermal_fairness_calculator.dart` (hàm thuần `computeThermalFairness`):
- Công thức: lấy tốc độ trung vị các lần test **cùng SSID** lúc máy không nóng (`thermalStatus < 2`) vs lúc nóng (`>= 2`) từ chính lịch sử của user (không phải hằng số đoán trước) → % chênh lệch = fairness index (clamp 0–90%). Nếu test hiện tại đang throttle, suy ra "true speed" = tốc độ đo được / (1 - fairness/100).
- Card mới trong `test_detail_screen.dart` (`_buildThermalFairnessCard`, chỉ hiện khi `thermalStatus >= 2` **và** đủ mẫu lịch sử cả 2 phía) hiện song song tốc độ thô (đã có sẵn ở card khác) và true speed ước tính + % mất do nhiệt.
- Test: `test/p56_thermal_fairness_test.dart` (4 case: thiếu dữ liệu, đủ dữ liệu, test hiện tại không throttle, clamp 90%).

ponytail: chưa áp dụng logic này sang P31 (ISP dispute report) như note liên quan — để làm khi implement P31, tránh coupling 2 ticket vào cùng 1 lần đổi.
