# T95 — Flagship: VIP key revocation list (CRL) nhẹ, ký offline

- **REQ:** audit round mới 2026-08-15 (claude subagent + agy)
- **Priority:** P1 · **Status:** 🔲 todo (ý tưởng flagship, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/vip/signed_vip_key.dart`, `packages/ad_sdk/lib/src/vip/vip_manager.dart`

## Vì sao độc quyền
SDK đã có VIP key Ed25519 offline-verified với expiry + bundle-id binding (AVP2, từ 2.0.0) — khái niệm mà AppLovin MAX raw/Google Mobile Ads raw/wrapper khác không có. Giới hạn còn lại đã biết (README tự nhận, có chủ đích lúc thiết kế): 1 key lộ ra vẫn dùng được vĩnh viễn, không có kênh thu hồi.

## Ý tưởng
Host fetch định kỳ (1 lần/ngày, cache local, fail-open nếu không mạng — nhất quán hướng offline-first của SDK) 1 JSON nhỏ ký bởi cùng private key, chứa danh sách `kid` bị thu hồi. `verifySignedVipKey` check thêm key đó có trong CRL không trước khi chấp nhận.

## Việc cần làm (đề xuất, chưa code)
- [ ] Thiết kế format CRL JSON + cơ chế ký/verify tái dùng hạ tầng Ed25519 sẵn có.
- [ ] Cơ chế fetch + cache local, fail-open nếu offline (không được chặn user hợp lệ vì mất mạng).
