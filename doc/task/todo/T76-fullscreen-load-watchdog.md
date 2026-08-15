# T76 — Load watchdog/timeout cho fullscreen ad load thường (không chỉ on-demand rewarded)

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart`

## Vấn đề (Why)
SDK đã có timeout cho on-demand rewarded load, nhưng preload/load thường của interstitial/rewarded vẫn phụ thuộc hoàn toàn vào callback native SDK — nếu native SDK im lặng, không có watchdog.

## Đề xuất
Thêm watchdog timer tương tự on-demand rewarded cho preload/load thường, timeout → coi như load fail, retry theo backoff hiện có.

## Acceptance criteria
- [ ] Test: adapter không gọi callback trong X giây → slot tự chuyển về trạng thái fail thay vì treo vô hạn.
