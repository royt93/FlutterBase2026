# T85 — Pinning-wall Dart/CocoaPods cần doctor-check/matrix test tự động

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `CLAUDE.md`, `packages/ad_sdk/pubspec.yaml`, `.github/workflows/test.yml`

## Vấn đề (Why)
`CLAUDE.md` đã ghi rõ 2 pinning wall (Dart-level quanh `google_mobile_ads`/`gma_mediation_applovin`, CocoaPods-level quanh `AppLovinSDK` exact version). `pubspec.yaml` của package pass riêng lẻ chưa chứng minh consuming app thật có pod graph hợp lệ khi thêm mediation plugin — hiện chỉ verify thủ công mỗi lần release.

## Đề xuất
Script/CI job thử resolve pod graph + `pub get` với tổ hợp version pin thật của 1 consuming app mẫu (fixture nhỏ), fail sớm nếu lệch, thay vì chỉ note thủ công trong CLAUDE.md.

## Acceptance criteria
- [ ] CI job mới (hoặc script chạy trước release) phát hiện được xung đột pin nếu cố tình đổi version không tương thích.
