# P10 — Doc trỏ tới `AppSnackbar` không tồn tại + snackbar pattern không nhất quán

- **Priority:** P0 · **Severity:** HIGH · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận toàn bộ 5 nguồn]** codex CLI, claude CLI, agy CLI, cả 2 subagent đọc source — tất cả độc lập chỉ ra cùng vấn đề.
- **Files:** `CLAUDE.md`, `doc/init.md`, `lib/mckimquyen/util/ui_utils.dart`, `lib/mckimquyen/widget/wifi_stressor/wifi_stressor_screen.dart`, `lib/mckimquyen/widget/wifi_stressor/presentation/schedule_screen.dart`, `lib/mckimquyen/widget/wifi_stressor/presentation/test_detail_screen.dart`

## Vấn đề
`CLAUDE.md` và `doc/init.md` đều ghi "dùng `AppSnackbar`, không dùng `Get.snack`" — nhưng verify trực tiếp (`grep -rn "class AppSnackbar" lib/`) cho kết quả **rỗng**: class này không tồn tại trong repo. Pattern thật đang dùng là `UIUtils.showToast` (`util/ui_utils.dart:907`). Đồng thời một số nơi lại dùng raw `ScaffoldMessenger.of(context).showSnackBar` thay vì `UIUtils.showToast`:
- `wifi_stressor_screen.dart:127,147`
- `schedule_screen.dart:107`
- `test_detail_screen.dart` (theo agy CLI, cùng vị trí tương tự)

Không có `Get.snack(` nào trong code (verify: đã grep sạch) — vế đó của quy ước không bị vi phạm, nhưng vế "dùng AppSnackbar" trỏ tới component ma, và 3 file trên còn dùng cách thứ 3 (raw `ScaffoldMessenger`) không khớp cả 2 pattern trong doc.

## Việc cần làm (đề xuất — cần quyết định hướng trước khi code, chưa code)
Cần chọn 1 trong 2 hướng (đề xuất hỏi user hoặc tự quyết theo hướng ít phá vỡ nhất):
1. **Sửa doc** (`CLAUDE.md` + `doc/init.md`): đổi "dùng `AppSnackbar`" → "dùng `UIUtils.showToast`" (khớp thực tế code hiện tại, không đổi code).
2. **Sửa code**: rename `UIUtils.showToast` → tạo helper `AppSnackbar.show(...)` (hoặc rename thẳng), rồi sửa 3 file dùng raw `ScaffoldMessenger` sang gọi qua helper mới — khớp đúng nghĩa đen của doc.

Khuyến nghị: hướng 1 (sửa doc) rẻ hơn, ít rủi ro regression hơn — nhưng vẫn nên gộp sửa 3 file dùng raw `ScaffoldMessenger` sang `UIUtils.showToast` để nhất quán toàn app dù chọn hướng nào.

## Acceptance criteria
- [ ] Quyết định hướng (sửa doc hoặc sửa code) — ghi lại lý do chọn.
- [ ] Doc và code khớp nhau: không còn tài liệu nào trỏ tới component không tồn tại.
- [ ] 3 vị trí dùng raw `ScaffoldMessenger.showSnackBar` chuyển sang pattern thống nhất của app.
