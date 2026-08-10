# P21 — Comparison screen: giới hạn số test so sánh + fix layout clipping

- **Priority:** P2 · **Severity:** LOW · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/comparison_screen.dart`, `controllers/history_controller.dart:53-58`

## Vấn đề
`comparison_screen.dart` không giới hạn số test được chọn để so sánh (`history_controller.dart:53-58`). Cột metric (dòng 247, 288, 325) không có `FittedBox`/ellipsis — khi so sánh nhiều test, text bị vỡ layout/clip.

## Việc cần làm (đề xuất, chưa code)
- Đặt giới hạn hợp lý số test so sánh cùng lúc (VD 2-4), disable checkbox khi đạt giới hạn, kèm thông báo.
- Bọc text ở cột metric bằng `FittedBox`/`Text(overflow: TextOverflow.ellipsis)` để không vỡ layout khi tên dài.

## Acceptance criteria
- [ ] Chọn quá giới hạn test bị chặn với thông báo rõ ràng.
- [ ] So sánh với tên/giá trị dài không làm vỡ layout trên màn hình nhỏ.
