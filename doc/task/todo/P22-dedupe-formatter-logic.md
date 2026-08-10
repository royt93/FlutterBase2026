# P22 — Gộp logic format ngày giờ + ngưỡng dBm bị copy-paste

- **Priority:** P3 · **Severity:** LOW · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source
- **Files:** `test_detail_screen.dart:492-513`, `summary_stats_card.dart:181-204`, `network_dashboard.dart:36-43`, `test_result.dart:102-111`, `lib/mckimquyen/formatter/`

## Vấn đề
2 cặp logic bị copy-paste độc lập, tương lai dễ drift nếu chỉnh 1 chỗ quên chỗ khác:
1. `_formatDateTime`/`months` — copy giữa `test_detail_screen.dart:492-513` và `summary_stats_card.dart:181-204`, thay vì dùng chung `lib/mckimquyen/formatter/`.
2. Ngưỡng phân loại tín hiệu dBm — copy giữa `network_dashboard.dart:36-43` và `test_result.dart:102-111`.

## Việc cần làm (đề xuất, chưa code)
- Chuyển `_formatDateTime`/`months` thành 1 hàm chung trong `lib/mckimquyen/formatter/`, 2 file gọi lại hàm chung.
- Chuyển ngưỡng dBm thành 1 constant/hàm chung (VD trong `common/const/` hoặc `formatter/`), 2 file dùng lại.

## Acceptance criteria
- [ ] Chỉ còn 1 nguồn sự thật cho mỗi logic, không còn copy-paste.
- [ ] Test cũ của 2 màn hình vẫn pass sau khi refactor.
