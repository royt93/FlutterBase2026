# P16 — Heatmap drill-down: tap cell mở `TestDetailScreen`

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** **[đồng thuận mạnh 3 nguồn]** codex CLI + agy CLI + subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/heatmap_screen.dart`, `test_detail_screen.dart`

## Vấn đề / cơ hội
Cả 3 nguồn audit độc lập cùng đề xuất tính năng này — tín hiệu đồng thuận mạnh, có thể coi là quick-win vì hạ tầng (`TestDetailScreen` đã tồn tại đầy đủ) đã có sẵn, chỉ thiếu liên kết điều hướng. Hiện tại tap vào 1 hàng/cell trên heatmap (`heatmap_screen.dart:11-75`) không làm gì cả.

## Việc cần làm (đề xuất, chưa code)
- Thêm `GestureDetector`/`InkWell` lên mỗi hàng test trong heatmap, `onTap` → `Get.to(() => TestDetailScreen(...))` với đúng `TestResult` của hàng đó.
- Xem P07 trước khi làm — đảm bảo route này không rơi vào crash risk `Get.find<HistoryController>()` (nếu điều hướng không qua `HistoryScreen`, cần đảm bảo controller đã registered).

## Acceptance criteria
- [ ] Tap vào hàng bất kỳ trên heatmap mở đúng `TestDetailScreen` của test đó.
- [ ] Không crash nếu mở heatmap không qua flow History (do phụ thuộc P07).
