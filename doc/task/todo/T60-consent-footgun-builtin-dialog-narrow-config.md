# T60 — Footgun `_footgunBlocked` không được clear khi dùng dialog built-in + `autoRequestUmpConsent:false`

- **REQ:** audit round mới 2026-08-15 (claude subagent + agy, đã verify độc lập — CONFIRMED, phạm vi hẹp)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/lib/src/consent/consent_manager.dart:136,185-191`, `packages/ad_sdk/lib/src/core/ad_manager.dart:624,1597-1600`

## Vấn đề (Why)
Verified: chỉ trip khi host set `autoRequestUmpConsent: false` (tự chạy UMP lúc khác) NHƯNG vẫn để `autoShowConsentDialog: true` (dialog built-in mặc định), quên tự gọi `requestUmpConsent()`/`setConsent()`. `ConsentManager.showDialog()`/`_setInternal()` chỉ `_persist()` + `_applyToProviders()`, không đụng `AdManager._footgunBlocked` — cờ này chỉ được clear trong `AdManager.setConsent()`. Config mặc định (`autoRequestUmpConsent:true`, phổ biến nhất) đi qua `requestUmpConsent()` nội bộ, KHÔNG bị ảnh hưởng. Đây là phần dư sót lại của bug C1 (audit 20260802), thu hẹp còn đúng 1 tổ hợp cấu hình.

## Đề xuất
`ConsentManager.showDialog()`/`_setInternal()` gọi thêm hook clear `_footgunBlocked` trên `AdManager` (giống `setConsent()`), hoặc route built-in dialog qua cùng path `AdManager.setConsent()`.

## Acceptance criteria
- [ ] Test dựng `AdManager(autoRequestUmpConsent:false)` + dialog built-in trả lời → `canRequestAds` = true sau đó, không kẹt vĩnh viễn.
- [ ] `flutter test` pass, không regression config mặc định.
