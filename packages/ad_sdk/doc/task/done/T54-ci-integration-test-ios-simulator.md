# T54 — CI chỉ chạy `integration_test/` trên Android, không có job iOS

- **REQ:** phát hiện qua audit round 8 (2026-07-19), finding N5
- **Priority:** P2 (Medium — regression iOS-only, ví dụ T43 ATT/UMP no-timeout, chỉ bắt được thủ công) · **Status:** ✅ done (2026-07-20)
- **Files:** `.github/workflows/test.yml`

## Vấn đề (Why)
Job `sdk-integration` chỉ chạy trên Android emulator. Các regression đặc thù iOS Simulator (ATT/UMP native prompt, App-Open auto-redirect trên splash chain) chỉ được bắt qua test tay, không có trong CI.

## Đề xuất
Thêm job `sdk-integration-ios` chạy cùng bộ `integration_test/` trên iOS Simulator (macOS runner), dùng `SKIP_SPLASH_AD`/`SKIP_ATT`/`SKIP_UMP` dart-define để tránh kẹt splash-chain do native prompt không tự trả lời được trên CI.

## Acceptance criteria
- [x] Job mới `sdk-integration-ios` trong `test.yml`, YAML hợp lệ.
- [x] Boot iPhone 15 Simulator, `pod install`, chạy `integration_test` với 3 dart-define skip flag.
- [x] Không phá job hiện có (`sdk`, `sdk-integration`, `host`).

## Đã verify (2026-07-20)
Thêm job tại `.github/workflows/test.yml:67`. YAML validate qua `ruby -ryaml`. Xem `doc/audit/audit_claude.md` round 9.
