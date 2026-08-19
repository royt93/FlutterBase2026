# T95 — Flagship: VIP key revocation list (CRL) nhẹ, ký offline

- **REQ:** audit round mới 2026-08-15 (claude subagent + agy)
- **Priority:** P1 · **Status:** 🔲 todo (ý tưởng flagship, chưa thiết kế chi tiết)
- **Files:** `packages/ad_sdk/lib/src/vip/signed_vip_key.dart`, `packages/ad_sdk/lib/src/vip/vip_manager.dart`

## Vì sao độc quyền
SDK đã có VIP key Ed25519 offline-verified với expiry + bundle-id binding (AVP2, từ 2.0.0) — khái niệm mà AppLovin MAX raw/Google Mobile Ads raw/wrapper khác không có. Giới hạn còn lại đã biết (README tự nhận, có chủ đích lúc thiết kế): 1 key lộ ra vẫn dùng được vĩnh viễn, không có kênh thu hồi.

## Ý tưởng
Host fetch định kỳ (1 lần/ngày, cache local, fail-open nếu không mạng — nhất quán hướng offline-first của SDK) 1 JSON nhỏ ký bởi cùng private key, chứa danh sách `kid` bị thu hồi. `verifySignedVipKey` check thêm key đó có trong CRL không trước khi chấp nhận.

## Việc cần làm (đề xuất, chưa code)
- [x] Thiết kế format CRL JSON + cơ chế ký/verify tái dùng hạ tầng Ed25519 sẵn có.
- [x] Cơ chế fetch + cache local, fail-open nếu offline (không được chặn user hợp lệ vì mất mạng).

## Đã làm (2026-08-16)

Format thực tế đơn giản hơn JSON đề xuất — tái dùng đúng scheme pipe-delimited
`verifySignedVipKey` đã có (không phải JSON): payload
`<issuedAtEpochSeconds>|<kid1,kid2,...>`, đóng gói `CRL1.<b64url(payload)>.<b64url(sig)>`
— cùng `Ed25519`, cùng rotation-key-list (comma-separated public keys) cơ chế
`verifySignedVipKey` đang dùng, ký bằng CHÍNH private key hiện có
(`tool/vip_mint.dart`), không cần key mới.

- `lib/src/vip/signed_vip_key.dart` — thêm `VipRevocationList` (immutable:
  `revokedKeyIds` + `issuedAt`) và `Future<VipRevocationList> verifySignedCrl(...)`
  — verify chữ ký + parse, throw `VipKeyException` khi sai format/chữ ký
  (reuse các helper private `_b64urlDecode`/`_b64AnyDecode`/`_ed25519` đã có
  trong file).
- `tool/vip_crl_mint.dart` (mới) — mint CRL offline:
  `dart run tool/vip_crl_mint.dart --priv <b64privkey> --kids k1,k2,k3`.
  Copy y hệt cấu trúc `tool/vip_mint.dart` (parse args, `_fail`).
- `lib/src/vip/vip_revocation_provider.dart` (mới) — interface
  `VipRevocationProvider.fetchSignedCrl()` (trả về raw signed CRL string hoặc
  `null`), mirror đúng shape `RemoteAdSafetyProvider` (T88) để host tự chọn
  transport (Firebase Remote Config, static JSON endpoint, ...).
- `lib/src/vip/vip_manager.dart` — thêm:
  - `refreshRevocationList({required publicKeyBase64, required revocationProvider})`
    — fetch, verify, so `issuedAt` với bản cache hiện tại (chỉ áp dụng khi MỚI
    HƠN — chặn replay CRL cũ để "ẩn" revocation mới), rồi persist + áp dụng.
    **Fail-open** ở MỌI bước lỗi (provider throw, trả `null`, chữ ký sai,
    CRL cũ hơn) — không bao giờ chặn redeem hợp lệ vì lý do hạ tầng CRL.
  - `_ensureCachedRevocationLoaded(publicKeyBase64)` — load 1 lần/instance CRL
    đã cache từ disk, RE-VERIFY lại chữ ký trước khi tin (không tin bản JSON
    thô đã lưu, kể cả do chính SDK ghi) — offline-first, redeem vẫn chặn được
    kid đã revoke dù chưa gọi `refreshRevocationList` lại sau khi app restart.
  - `redeemSignedKey` — sau khi `verifySignedVipKey` pass, thêm 1 bước check
    `_revokedKeyIds.contains(parsed.keyId)` trước khi claim one-time-use →
    trả `SignedVipRedeemResult.invalid('key revoked')`.
- `lib/src/utils/ad_preferences.dart` — `getVipRevocationCacheRaw()`/
  `setVipRevocationCacheRaw(String code)`, lưu RAW signed CRL string (không
  lưu plaintext đã parse) — buộc phải re-verify mỗi lần đọc.
- `lib/applovin_admob_sdk.dart` — export `VipRevocationList`, `verifySignedCrl`,
  `VipRevocationProvider`.
- Scope quyết định KHÔNG làm (tự quyết, để tối giản đúng phạm vi ticket):
  không claw-back VIP đã redeem trước khi bị revoke (ticket chỉ yêu cầu chặn
  redeem tương lai — "check trước khi chấp nhận"); không thêm field CRL vào
  `AdConfig`/wiring `AdManager.initialize` — `publicKeyBase64`/provider truyền
  trực tiếp per-call giống hệt convention sẵn có của `redeemSignedKey`, tránh
  plumbing thừa.
- Test mới: `test/vip_revocation_test.dart` (13 test) — unit `verifySignedCrl`
  (chấp nhận hợp lệ/rotation-key-list, từ chối tampered/wrong-key/malformed)
  + tích hợp `VipManager` (kid bị revoke bị chặn, kid sạch vẫn redeem được,
  fail-open khi provider throw/trả null/chữ ký sai, chống replay CRL cũ, cache
  sống sót qua instance mới mô phỏng app restart).
- `flutter analyze`: No issues found! `flutter test`: 810/810 pass.
