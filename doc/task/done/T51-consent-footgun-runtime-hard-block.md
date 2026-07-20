# T51 — Consent footgun chỉ chặn bằng `assert()`, strip ở release

- **REQ:** phát hiện qua audit round 8 (2026-07-19), finding N2
- **Priority:** P1 (Medium/High risk — ads request được không consent hợp lệ ở release) · **Status:** ✅ done (2026-07-20)
- **Files:** `packages/ad_sdk/lib/src/core/ad_manager.dart` (+ test tương ứng)

## Vấn đề (Why)
Khi host quên gọi UMP/CMP trước `initialize()`, `consentFootgunWarning` chỉ dùng `assert()` — bị strip hoàn toàn ở release build, nên production không có gì chặn thật, chỉ log-only (nếu còn log).

## Đề xuất
Thêm hard-block runtime thật, gate qua `kReleaseMode`, tự clear + refill khi `setConsent()` được gọi.

## Acceptance criteria
- [x] Release build: thiếu consent trước `initialize()` → chặn request ads thật (không chỉ assert).
- [x] `setConsent()` (host tự gọi hoặc do `requestUmpConsent()` nội bộ) tự clear block + trigger refill.
- [x] Test mới cho cả 2 nhánh (block active, block cleared).

## Đã verify (2026-07-20)
Thêm field `_footgunBlocked` trong `ad_manager.dart`, gate `kReleaseMode`. `flutter test` (packages/ad_sdk): 649/649 pass. Xem `doc/audit/audit_claude.md` round 9, `CHANGELOG.md` [1.2.2].
