# T46 — example app pin flutter_lints thấp hơn package cha

- **REQ:** phát hiện qua audit sâu 2026-07-19 (agent "Audit ad_sdk example app for gaps")
- **Priority:** P4 (cosmetic, không ảnh hưởng runtime) · **Status:** ✅ done (2026-07-19)
- **Files:** `packages/ad_sdk/example/pubspec.yaml`, `packages/ad_sdk/pubspec.yaml`

## Vấn đề (Why)
`packages/ad_sdk/example/pubspec.yaml` ghim `flutter_lints: ^4.0.0`, trong khi `packages/ad_sdk/pubspec.yaml` (package cha mà example đang demo) dùng `flutter_lints: ^6.0.0`. Example đang chạy lint set cũ/lỏng hơn chính package nó minh họa — có thể để lọt regression lint mà CI job `sdk` lẽ ra phải bắt được.

## Giải pháp đã áp dụng
Bump `flutter_lints` trong `example/pubspec.yaml` lên `^6.0.0` khớp package cha, `flutter pub get` xong không xung đột.

## Acceptance criteria
- [x] `example/pubspec.yaml` dùng `flutter_lints: ^6.0.0`.
- [x] `flutter analyze` trong `packages/ad_sdk/example` sạch (0 issues) sau khi bump — không phát sinh lint mới.
