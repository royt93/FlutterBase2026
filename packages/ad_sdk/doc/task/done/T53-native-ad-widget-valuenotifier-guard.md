# T53 — Native ad widget ghi `ValueNotifier` không guard adapter disposed

- **REQ:** phát hiện qua audit round 8 (2026-07-19), finding N4
- **Priority:** P2 (Medium — crash risk khi widget dispose giữa lúc callback đang bay) · **Status:** ✅ done (2026-07-20)
- **Files:** `packages/ad_sdk/lib/src/widgets/native_ad_widget.dart` (+ test tương ứng)

## Vấn đề (Why)
Callback `MaxNativeAdView`/`NativeAdListener` ghi thẳng vào `ValueNotifier` mà không kiểm tra adapter đã dispose/chưa init xong — race nếu widget bị dispose giữa lúc ad network gọi callback về.

## Đề xuất
Guard `adapter.isInitialised` trước khi ghi `ValueNotifier` hoặc fire click event, cùng pattern đã áp dụng cho banner/mrec view.

## Acceptance criteria
- [x] Callback native ad guard `adapter.isInitialised` trước khi ghi state.
- [x] Test mới mô phỏng callback đến sau dispose, xác nhận không crash/không ghi.
- [x] `flutter test` pass, không regression.

## Đã verify (2026-07-20)
Sửa `native_ad_widget.dart` theo đúng pattern banner/mrec đã có sẵn. `flutter test` (packages/ad_sdk): 649/649 pass. Xem `doc/audit/audit_claude.md` round 9, `CHANGELOG.md` [1.2.2].
