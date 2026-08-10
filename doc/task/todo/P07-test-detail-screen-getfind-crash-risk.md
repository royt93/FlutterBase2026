# P07 — `TestDetailScreen` crash risk khi mở trực tiếp (không qua History)

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** 🔲 todo
- **Nguồn:** codex CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/test_detail_screen.dart`

## Vấn đề
Dòng 598 gọi `Get.find<HistoryController>()` lúc xoá kết quả, giả định controller đã được register (đúng khi mở từ `HistoryScreen`). Nếu `TestDetailScreen` được mở trực tiếp bằng route khác (deep link, notification tap...) mà `HistoryController` chưa `Get.put`, hành động xoá sẽ crash với `"HistoryController" not found`.

## Bằng chứng
- `test_detail_screen.dart:598`.

## Việc cần làm (đề xuất, chưa code)
- Guard bằng `Get.isRegistered<HistoryController>()` trước khi `Get.find`, hoặc đảm bảo route tới `TestDetailScreen` luôn đi qua nơi đã `Get.put(HistoryController())` trước (audit lại toàn bộ nơi push `TestDetailScreen`, bao gồm route mới ở P16 heatmap drill-down).

## Acceptance criteria
- [ ] Mở `TestDetailScreen` trực tiếp (không qua `HistoryScreen`) rồi bấm xoá — không crash.
- [ ] Widget test dựng `TestDetailScreen` standalone (không pre-register `HistoryController`), verify hành vi xoá không throw.
