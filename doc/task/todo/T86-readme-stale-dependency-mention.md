# T86 — README nhắc dependency stale (`google_mobile_ads` 6.x trong khi pubspec dùng `^7.0.0`)

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/README.md:222,664`, `packages/ad_sdk/pubspec.yaml:58`

## Vấn đề (Why)
README vẫn nhắc `google_mobile_ads 6.x` trong khi package dùng `^7.0.0`. Cùng nhóm debt với T61 (default UMP sai) — docs pub.dev có thể dẫn dev debug nhầm version behavior.

## Đề xuất
Rà soát toàn README, đồng bộ version mention với `pubspec.yaml` hiện tại.

## Acceptance criteria
- [ ] README không còn version mention lệch với pubspec.
