# T77 — Event stream cho gate/skip decision (`AdGateEvent`/`AdSkipEvent`) thay vì chỉ log text

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart:2271,2302,2981`, `packages/ad_sdk/lib/src/event/ad_event.dart`

## Vấn đề (Why)
Quyết định gate/skip (vd VIP suppress, cap chặn, cooldown) hiện chỉ đi qua `SafeLogger`. App muốn audit funnel/dashboard phải tự parse log text.

## Đề xuất
Emit structured event (`AdGateEvent`/`AdSkipEvent`) vào event stream đã có sẵn, kèm lý do skip.

## Acceptance criteria
- [ ] Mỗi lần gate/skip 1 ad, event tương ứng được emit với đủ context (loại ad, lý do).
- [ ] Test xác nhận event emit đúng cho từng lý do skip chính (VIP, cap, cooldown, consent).
