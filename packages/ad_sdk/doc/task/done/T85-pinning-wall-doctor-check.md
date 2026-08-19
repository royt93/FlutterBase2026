# T85 — Pinning-wall Dart/CocoaPods cần doctor-check/matrix test tự động

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P1 · **Status:** ✅ done
- **Files:** `CLAUDE.md`, `packages/ad_sdk/pubspec.yaml`, `.github/workflows/test.yml`

## Vấn đề (Why)
`CLAUDE.md` đã ghi rõ 2 pinning wall (Dart-level quanh `google_mobile_ads`/`gma_mediation_applovin`, CocoaPods-level quanh `AppLovinSDK` exact version). `pubspec.yaml` của package pass riêng lẻ chưa chứng minh consuming app thật có pod graph hợp lệ khi thêm mediation plugin — hiện chỉ verify thủ công mỗi lần release.

## Đề xuất
Script/CI job thử resolve pod graph + `pub get` với tổ hợp version pin thật của 1 consuming app mẫu (fixture nhỏ), fail sớm nếu lệch, thay vì chỉ note thủ công trong CLAUDE.md.

## Acceptance criteria
- [x] CI job mới (hoặc script chạy trước release) phát hiện được xung đột pin nếu cố tình đổi version không tương thích.

## Đã làm (2026-08-16)
Tạo `packages/ad_sdk/tool/pinning_check_app/` — fixture Flutter app (chỉ platform iOS) phụ thuộc `applovin_admob_sdk` qua `path: ../..`, `gma_mediation_applovin: 2.5.2` (pin cứng, không range — để không tự trôi qua thời gian), `dependency_overrides: { applovin_max: 4.6.0 }` đúng combo CLAUDE.md đã ghi là hoạt động được.

Script `tool/check_pinning_wall.sh` — `flutter pub get` + `cd ios && pod install --repo-update`, exit code tự nhiên theo `pod install` (không cần logic check riêng). CI: job mới `pinning-wall` (macOS runner) chạy script này mỗi push/PR.

**Verify thật (máy này có sẵn CocoaPods 1.17.0 + Xcode 26.4.1):**
- Combo đúng (`applovin_max: 4.6.0` override) → `pod install` resolve OK, `AppLovinSDK (13.5.0)` — script exit 0.
- Cố tình đổi thành combo XUNG ĐỘT (`applovin_max: 4.6.4`, đúng như package tự khai `^4.6.4`, KHÔNG override) → `pod install` FAIL đúng y hệt lỗi CLAUDE.md mô tả (`AppLovinSDK (= 13.6.3)` vs `AppLovinSDK (= 13.5.0)`) — script exit 1.
- Khôi phục combo đúng → xanh trở lại.

Dọn sạch mọi file generated/machine-specific trước khi commit (`ios/Pods`, `Podfile.lock`, `ios/Flutter/Generated.xcconfig`, `ephemeral/`, `.symlinks` — theo đúng `.gitignore` chuẩn `flutter create` sinh ra, đã copy vào fixture). `flutter analyze` fixture sạch, `flutter analyze` package chính không bị ảnh hưởng bởi fixture mới. Validate YAML bằng `python3 -c "import yaml..."`.
