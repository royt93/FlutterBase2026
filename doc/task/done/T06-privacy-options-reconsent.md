# T06 — Privacy Options entry point bền vững + re-consent

- **REQ:** 6, 7
- **Priority:** P1 · **Severity:** HIGH · **Status:** done
- **Files:** `core/ad_manager.dart`, `core/ump_consent.dart`, `consent/consent_manager.dart`, host settings/VIP/privacy screen

## Vấn đề (Why)
Google yêu cầu user **luôn** có cách thay đổi consent (Privacy Options). SDK có `ConsentManager.showDialog` nhưng **không bắt buộc** và không expose UMP privacy-options form. Nếu host quên wiring, user bị khoá lựa chọn đầu — vi phạm GDPR.

## Acceptance criteria
- [x] SDK expose API mở **UMP privacy options form** (`ConsentForm.showPrivacyOptionsForm`) khi khả dụng. Implement là `AdManager().showPrivacyOptions()` (parameterless — không cần `BuildContext` vì chỉ gọi native form của Google; gọn hơn spec gốc `showPrivacyOptions(context)`).
- [x] Có getter `AdManager().isPrivacyOptionsRequired()` cho biết privacy options có sẵn không (để host ẩn/hiện nút).
- [x] Tài liệu MUST trong README (`packages/ad_sdk/README.md`, mục "Privacy Options entry point"): host phải đặt nút "Privacy Settings" thường trực; kèm ví dụ `ListTile` wiring.
- [x] Debug log trong `ump_consent.dart` log rõ khi no-op ("privacy options: not required — no-op") và khi form hiện xong, đủ để dev nhận biết qua log nếu quên wiring.
- [x] Sau khi user đổi consent → re-apply providers ngay (npa/RDP cập nhật) — verify qua `_RecordingAdapter.applied`.

## Test
- [x] Unit: gọi showPrivacyOptions khi form available → gọi UMP API (mock). (`test/privacy_options_test.dart`)
- [x] Unit: đổi consent → applyConsent được gọi lại trên adapter đang active. (`test/privacy_options_test.dart`)

**Verification (2026-07-06):** `flutter analyze --no-pub` sạch. `flutter test test/privacy_options_test.dart` 6/6 xanh. Full suite `flutter test` 290/290 xanh, 0 regression.
