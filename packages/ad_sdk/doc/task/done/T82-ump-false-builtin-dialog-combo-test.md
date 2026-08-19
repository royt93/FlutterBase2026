# T82 — Thiếu test cho tổ hợp `autoRequestUmpConsent:false` + dialog built-in — đi kèm T60

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P1 · **Status:** ✅ done (đã có sẵn, xác nhận khi verify)
- **Files:** `packages/ad_sdk/test/consent_manager_test.dart` hoặc `packages/ad_sdk/test/ad_manager_core_test.dart`

## Vấn đề (Why)
Chưa có test nào dựng `AdManager(autoRequestUmpConsent: false)`, trigger footgun, rồi verify `canRequestAds` sau khi dialog built-in trả lời. Gap này sống sót qua nhiều vòng audit vì chưa từng có test khoanh vùng đúng tổ hợp cấu hình gây bug T60.

## Đề xuất
Viết test đúng kịch bản trên, nên implement cùng lúc với fix T60.

## Acceptance criteria
- [x] Test mới fail trước khi fix T60, pass sau khi fix.

## Đã làm (2026-08-16) — REFUTED-AS-SEPARATE-GAP: đã có sẵn từ khi fix T60

Ticket này tự ghi "nên implement cùng lúc với fix T60" — và thực tế đã được implement đúng như vậy. Verify lại `test/ad_manager_core_test.dart`, group `'T60 — built-in consent dialog + autoRequestUmpConsent:false must still clear the footgun block'` (dòng ~1509-1564): dựng đúng `AdConfig(autoRequestUmpConsent: false, autoShowConsentDialog: true)`, trip footgun (`debugFootgunBlocked = true`), render dialog built-in thật qua `MaterialApp` + `tester.pumpAndSettle()`, tap nút "Đồng ý" thật, assert `mgr.canRequestAds` hồi phục `true` — đúng 100% kịch bản + acceptance criteria ticket này yêu cầu, không thiếu gì.

Không cần code/test mới — chỉ xác nhận qua verify, không phải giả-refute kiểu T57 (lần này ticket ĐÚNG là đã covered, chỉ là chưa tách thành work-item riêng khi đóng T60).

`flutter test`: 750/750 pass (đã chạy full suite trước đó), test T60 nằm trong đó chạy xanh.
