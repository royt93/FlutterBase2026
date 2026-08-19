# T60 — Footgun `_footgunBlocked` không được clear khi dùng dialog built-in + `autoRequestUmpConsent:false`

- **REQ:** audit round mới 2026-08-15 (claude subagent + agy, đã verify độc lập — CONFIRMED, phạm vi hẹp)
- **Priority:** P2 · **Status:** ✅ done (2026-08-15)
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (`_maybeScheduleConsentDialog`, `debugConsentManager` seam mới), `packages/ad_sdk/test/ad_manager_core_test.dart`

## Vấn đề (Why)
Verified: chỉ trip khi host set `autoRequestUmpConsent: false` (tự chạy UMP lúc khác) NHƯNG vẫn để `autoShowConsentDialog: true` (dialog built-in mặc định), quên tự gọi `requestUmpConsent()`/`setConsent()`. `ConsentManager.showDialog()`/`_setInternal()` chỉ `_persist()` + `_applyToProviders()`, không đụng `AdManager._footgunBlocked` — cờ này chỉ được clear trong `AdManager.setConsent()`. Config mặc định (`autoRequestUmpConsent:true`, phổ biến nhất) đi qua `requestUmpConsent()` nội bộ, KHÔNG bị ảnh hưởng. Đây là phần dư sót lại của bug C1 (audit 20260802), thu hẹp còn đúng 1 tổ hợp cấu hình.

## Đã làm (2026-08-15, TDD)
Không route qua `ConsentManager` (tránh coupling ngược sang `AdManager`) — sửa trực tiếp tại nơi built-in dialog thực sự được gọi: `AdManager._maybeScheduleConsentDialog()`. Sau khi `mgr.showDialog(...)` trả về và `_consent` được cập nhật, thêm đúng 2 dòng giống `setConsent()` đã làm: `_consentExplicitlySet = true; _footgunBlocked = false;`.

Thêm 1 test seam nhỏ (`debugConsentManager`, theo đúng pattern `debugVipManager`/`debugSetAdapter` có sẵn) để inject `ConsentManager` thật vào `AdManager` trong test mà không cần chạy native `initialize()`. Viết test trước (RED: `Expected: true, Actual: false` trên `canRequestAds` sau khi trả lời dialog), fix, GREEN. `flutter test`: 707/707 pass, `flutter analyze` sạch.

## Acceptance criteria
- [x] Test dựng `AdManager(autoRequestUmpConsent:false, autoShowConsentDialog:true)` + dialog built-in trả lời (tap "Allow") → `canRequestAds` = true sau đó, không kẹt vĩnh viễn.
- [x] `flutter test` pass (707/707), không regression config mặc định.
