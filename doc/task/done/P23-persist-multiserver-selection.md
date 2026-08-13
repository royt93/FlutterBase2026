# P23 — Lưu lựa chọn multi-server (Wave 7) qua restart app

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** codex CLI (audit độc lập)
- **Files:** `lib/mckimquyen/widget/wifi_stressor/stressor_controller.dart:143`

## Vấn đề
Lựa chọn multi-server (feature Wave 7) hiện chỉ tồn tại trong memory (`stressor_controller.dart:143`), mất khi tắt app — user phải chọn lại server mỗi lần mở app.

## Việc cần làm (đề xuất, chưa code)
- Lưu danh sách server đã chọn vào SharedPreferences (theo pattern `shared_preferences_util.dart` đã có sẵn) hoặc Hive, load lại lúc `StressorController.onInit()`.

## Acceptance criteria
- [ ] Chọn server, tắt app hoàn toàn, mở lại — lựa chọn server vẫn giữ nguyên.
- [ ] Unit test verify persistence round-trip.
