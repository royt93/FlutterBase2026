# T16 — Validate ad-unit-id (rỗng/định dạng) trong footgun warnings

- **REQ:** 1
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** todo
- **Files:** `core/ad_manager.dart` (`releaseFootgunWarnings` `:99-125`), `config/ad_config.dart`

## Vấn đề (Why)
`rewardedId` default `''` (`ad_config.dart:93`), không cảnh báo khi rỗng; không kiểm định dạng `ca-app-pub-...` cho AdMob (dễ nhầm id AppLovin ↔ AdMob). Lỗi chỉ lộ ở runtime với message native khó hiểu. Đã có sẵn cơ chế `releaseFootgunWarnings`.

## Acceptance criteria
- [ ] `releaseFootgunWarnings` cảnh báo: id bắt buộc rỗng, hoặc rewarded được kỳ vọng nhưng `rewardedId` rỗng.
- [ ] Với provider AdMob: cảnh báo nếu id không khớp pattern `ca-app-pub-...`.
- [ ] (Đã có) cảnh báo test-id trong release — giữ; bổ sung provider mismatch nếu phát hiện.
- [ ] Cảnh báo hiển thị ở release (log ERROR) + assert debug — theo pattern hiện có (`:441-444`).

## Test
- [ ] Unit: config id rỗng/sai định dạng → `releaseFootgunWarnings` trả cảnh báo tương ứng.
