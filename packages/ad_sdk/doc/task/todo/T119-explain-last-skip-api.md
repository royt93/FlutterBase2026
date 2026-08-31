# T119 — Idea: AdManager().explainLastSkip(AdSlotType) — bộ giải thích tại sao ad không hiện

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `lib/src/core/ad_manager.dart` (nơi các gate quyết định pass/fail), `lib/src/compliance/ad_event_log.dart` (tham khảo pattern ring-buffer)

## Vấn đề

README/CHANGELOG nhắc lại câu hỏi hỗ trợ phổ biến nhất của SDK quảng cáo: "ad không hiện, tại sao?" — hiện phải bật verbose log + đọc tag. Data đã tồn tại rải rác ở các gate (VIP/consent/cooldown/cap/network/dryRun), chỉ cần gom lại.

## Việc cần làm

- [ ] Ring buffer nhỏ (N quyết định gate gần nhất) mỗi loại ad
- [ ] `explainLastSkip(AdSlotType)` trả lý do skip gần nhất dạng human-readable
- [ ] Test: mỗi loại gate (VIP/consent/cooldown/cap/network/dryRun) trả đúng lý do tương ứng
