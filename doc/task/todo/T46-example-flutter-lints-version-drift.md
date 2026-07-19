# T46 — example app pin flutter_lints thấp hơn package cha

- **REQ:** phát hiện qua audit sâu 2026-07-19 (agent "Audit ad_sdk example app for gaps")
- **Priority:** P4 (cosmetic, không ảnh hưởng runtime) · **Status:** todo
- **Files:** `packages/ad_sdk/example/pubspec.yaml:20`, `packages/ad_sdk/pubspec.yaml:31`

## Vấn đề (Why)
`packages/ad_sdk/example/pubspec.yaml` ghim `flutter_lints: ^4.0.0`, trong khi `packages/ad_sdk/pubspec.yaml` (package cha mà example đang demo) dùng `flutter_lints: ^6.0.0`. Example đang chạy lint set cũ/lỏng hơn chính package nó minh họa — có thể để lọt regression lint mà CI job `sdk` lẽ ra phải bắt được.

## Đề xuất
Bump `flutter_lints` trong `example/pubspec.yaml` lên `^6.0.0` khớp package cha, chạy `flutter analyze` trong example để xử lý lint mới phát sinh (nếu có).

## Acceptance criteria
- [ ] `example/pubspec.yaml` dùng `flutter_lints: ^6.0.0`.
- [ ] `flutter analyze` trong `packages/ad_sdk/example` sạch (0 issues) sau khi bump.
