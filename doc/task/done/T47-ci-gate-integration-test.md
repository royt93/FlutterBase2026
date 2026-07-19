# T47 — CI chưa gate `integration_test/`

- **REQ:** phát hiện qua audit round 6 (2026-07-19), mục "Re-audit vòng 6"
- **Priority:** P3 (coverage gap, không block release) · **Status:** ✅ done (2026-07-19), chờ verify lượt CI đầu tiên
- **Files:** `.github/workflows/test.yml`

## Vấn đề (Why)
`.github/workflows/test.yml` trước đây chỉ chạy `flutter analyze` + `flutter test` (Dart VM, unit/widget) cho cả `packages/ad_sdk` và host app. 20 file trong `packages/ad_sdk/example/integration_test/` (mrec/native ad/arbitrator/fill-rate/consent-country/diagnostics demo…) chỉ được chạy tay trên simulator/device thật, không có gate tự động trong CI.

## Đề xuất
Thêm job mới `sdk-integration` dùng `reactivecircus/android-emulator-runner` để chạy `flutter test integration_test` trên emulator Android thật trong CI (ubuntu-latest + KVM enable step).

## Acceptance criteria
- [x] Job mới `sdk-integration` trong `.github/workflows/test.yml`, chạy `flutter test integration_test` trong `packages/ad_sdk/example`.
- [x] YAML hợp lệ (validate bằng `ruby -ryaml`).
- [ ] Xác nhận job chạy pass thật trên GitHub Actions (cần push/PR — chưa thực hiện, chờ user).

## Đã verify (2026-07-19)
Thêm job `sdk-integration` (API 34, `google_apis`, `x86_64`, KVM enable qua udev rule) giữa job `sdk` và `host`. AdMob App ID/unit IDs trong example đã là test ID của Google (xem CLAUDE.md), nên chạy tự động không rủi ro doanh thu/policy thật. YAML syntax validated (`ruby -ryaml -e "YAML.load_file(...); puts 'OK'"` → OK).

**Giới hạn đã biết:** job này chưa được xác nhận chạy pass thật trên GitHub Actions — cần một lượt CI thật (sau khi user push/mở PR) để xác nhận emulator boot + toàn bộ 20 file integration_test pass trong môi trường đó. Không tự push/trigger CI theo quy tắc đã thống nhất (user tự commit/push).
