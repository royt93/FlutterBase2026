# T82 — Thiếu test cho tổ hợp `autoRequestUmpConsent:false` + dialog built-in — đi kèm T60

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/test/consent_manager_test.dart` hoặc `packages/ad_sdk/test/ad_manager_core_test.dart`

## Vấn đề (Why)
Chưa có test nào dựng `AdManager(autoRequestUmpConsent: false)`, trigger footgun, rồi verify `canRequestAds` sau khi dialog built-in trả lời. Gap này sống sót qua nhiều vòng audit vì chưa từng có test khoanh vùng đúng tổ hợp cấu hình gây bug T60.

## Đề xuất
Viết test đúng kịch bản trên, nên implement cùng lúc với fix T60.

## Acceptance criteria
- [ ] Test mới fail trước khi fix T60, pass sau khi fix.
