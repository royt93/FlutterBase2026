# P15 — Heatmap: normalization + độ phân giải theo thời lượng test thật

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận]** codex CLI + agy CLI
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/heatmap_screen.dart`

## Vấn đề
2 hạn chế độc lập cùng bị chỉ ra:
1. Heatmap chỉ normalize màu theo **global max** (`heatmap_screen.dart:63-75`) — phòng/test yếu sóng bị "chìm" hoàn toàn về màu đỏ khi so với 1 test khác quá mạnh, mất chi tiết dao động nội bộ.
2. Grid luôn hardcode **24 cell** (`heatmap_screen.dart:15`) bất kể thời lượng test thật (test 10s burst vs test 300s stress) — mất chi tiết micro-stutter ở test dài.

## Việc cần làm (đề xuất, chưa code)
- Thêm toggle "global vs per-test normalization" — per-test normalize theo max/min của riêng test đó để vẫn thấy dao động nội bộ ở test yếu.
- Tính số cell theo thời lượng test thật (VD: 1 cell/giây tới ngưỡng tối đa hợp lý, hoặc downsample động) thay vì cố định 24.

## Acceptance criteria
- [ ] User có thể chuyển global/per-test normalization, thấy rõ khác biệt trên UI.
- [ ] Test 300s hiển thị chi tiết hơn test 10s trên heatmap (không cùng 24 cell cố định).
