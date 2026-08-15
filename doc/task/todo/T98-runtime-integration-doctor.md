# T98 — Flagship: Runtime integration doctor cho consuming app

- **REQ:** audit round mới 2026-08-15 (codex)
- **Priority:** P2 · **Status:** 🔲 todo (ý tưởng flagship, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/debug/integration_self_check.dart`, `packages/ad_sdk/lib/src/debug/ad_debug_overlay.dart`, `packages/ad_sdk/README.md:73`

## Vì sao độc quyền
Phần lớn lỗi ads SDK thật xảy ra ở integration layer (thiếu navigator key, route observer, ATT/UMP config, SKAdNetwork/Info.plist, Android manifest, mediation/pod graph), không phải Dart API logic. Package đã có self-check/debug overlay — nâng cấp thành "doctor" chạy runtime hoặc trong integration test sẽ là khác biệt rất thực tế so với SDK khác.

## Việc cần làm (đề xuất, chưa code)
- [ ] Mở rộng `integration_self_check.dart` check thêm: SKAdNetwork/Info.plist entries, Android manifest permissions/meta-data, pod graph version (đối chiếu pinning wall T85).
- [ ] Hiển thị kết quả doctor trong debug overlay, dạng pass/fail per check.
