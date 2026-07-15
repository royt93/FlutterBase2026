# T42 — Consent người dùng bị "quên" mỗi lần mở app

- **REQ:** ngoài phạm vi 7 yêu cầu gốc — tự phát hiện khi đối chiếu 6 tài liệu audit với code thật (2026-07-13)
- **Priority:** P0 (ảnh hưởng mọi lần khởi động app, mọi user) · **Status:** ✅ done (2026-07-14)
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart`, `packages/ad_sdk/test/consent_persistence_on_init_test.dart` (mới)

## Vấn đề (Why)
Thứ tự gọi thật của host app (`splash_screen.dart:195` rồi `:216`) là `requestUmpConsent()` (→ `setConsent(...)`) **trước** `initialize()`. Tại thời điểm đó `AdManager._consentManager` vẫn còn `null` (chưa bootstrap), nên `setConsent()` cũ chỉ set một biến RAM tạm (`_consent`) rồi return sớm — không ghi gì vào `ConsentManager`/đĩa. Ngay sau đó `initialize()` chạy `ConsentManager.bootstrap()`, load lại dữ liệu consent **cũ đã lưu từ phiên trước**, rồi ghi đè vô điều kiện lên `_consent` — xóa mất kết quả UMP vừa nhận được vài mili-giây trước đó. Kết quả: mỗi lần mở app, quyết định consent mới nhất của user (đồng ý/từ chối) bị âm thầm thay bằng giá trị cũ, dù không có lỗi/crash nào hiển thị ra ngoài.

## Giải pháp đã chọn
- Thêm field đệm `ConsentSettings? _pendingConsentSettings` trong `AdManager`.
- `setConsent()`: nếu `_consentManager` đã tồn tại (đã bootstrap), ghi thẳng qua `_consentManager!.set(...)` (persist ngay, không chờ init). Nếu chưa (đúng case bug), lưu tạm vào `_pendingConsentSettings` để `initialize()` áp dụng lại sau.
- `initialize()`: ngay sau khi `ConsentManager.bootstrap()` + `applyToProviders()` chạy xong (đã load xong dữ liệu cũ), nếu có `_pendingConsentSettings` thì ghi đè lại bằng giá trị đó (`consentMgr.set(pending, config: config)`), rồi đồng bộ `_consent`/`_adapter.applyConsent(...)`, và xóa buffer.
- `destroy()`: xóa `_pendingConsentSettings` khi teardown — một `setConsent()` bị đệm trước khi SDK bị `destroy()` không nên rò rỉ sang lần `initialize()` kế tiếp (destroy là hành động dọn dẹp tường minh, không phải resume).

## Acceptance criteria
- [x] `setConsent()` gọi trước `initialize()` phải "thắng" giá trị cũ đã lưu từ phiên trước, cả trong RAM (`AdManager().consent`) lẫn trên đĩa (`ConsentSettings` persisted qua `AdPreferences`).
- [x] Trường hợp không có `setConsent()` nào chờ (đường thường) vẫn load consent cũ bình thường — không regression.
- [x] Có test chứng minh bằng đường `initialize()` thật (không chỉ qua seam test `debugSetAdapter`), để xác nhận fix hoạt động đúng sau khi adapter native init thật sự thành công — dùng provider AppLovin (dễ giả lập init-thành-công thật hơn AdMob trong môi trường `flutter test`).

## Verify
`cd packages/ad_sdk && flutter test` → 550/550 pass (gồm 2 test mới trong `consent_persistence_on_init_test.dart`). `flutter analyze` → no issues.
