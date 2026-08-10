# P11 — Dọn force-null (`!`) còn sót lại (vi phạm quy ước "no `!`")

- **Priority:** P3 · **Severity:** LOW · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI, claude CLI, cả 2 subagent — cùng danh sách vị trí, đều xác nhận có guard, không crash thật.
- **Files:** nhiều file (xem danh sách dưới)

## Vấn đề
`doc/init.md` quy định "không dùng ... force null". Toàn bộ vị trí dưới đây **đều đã có null-guard trước hoặc được framework đảm bảo non-null** (đã verify, không phải crash thật) nhưng vẫn là literal `!` — vi phạm chữ của quy ước dù không vi phạm tinh thần an toàn.

## Bằng chứng (toàn bộ vị trí, đã verify từng dòng có guard)
- `lib/main.dart:101` — `child!` trong `MaterialApp.builder` (khó tránh do signature API Flutter).
- `splash_screen.dart:200,367,401,418` — `_eventListener!`, `adConfig.admob!` (đều có guard/assert liền kề).
- `util/exit_app.dart:13` — `currentBackPressTime!` (guard `== null ||` ngay trước).
- `stressor_controller.dart:469` — `_worstThermalStatus!` (short-circuit safe).
- `test_detail_screen.dart:300` — `result.roomTag!`.
- `room_comparison_screen.dart:49` — `r.roomTag!`.
- `heatmap_screen.dart:27,30` — `Color.lerp(...)!` ×2.

## Việc cần làm (đề xuất, chưa code)
- Thay từng `!` bằng null-safe pattern tương ứng (`??`, `if (x != null)`, pattern matching `if (x case final v?)`, hoặc early-return) theo case cụ thể.
- `main.dart:101` có thể giữ nguyên nếu team chấp nhận đây là exception hợp lệ do ràng buộc từ Flutter API — cần quyết định rõ, ghi vào doc nếu chấp nhận ngoại lệ.

## Acceptance criteria
- [ ] Không còn `!` nào trong `lib/mckimquyen/**` ngoại trừ exception đã được ghi nhận rõ trong doc (nếu có).
- [ ] `flutter analyze` sạch, test cũ không regress.
