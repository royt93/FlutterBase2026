# T18 — VIP key: signed keys offline (Ed25519) + one-time-use per-device

- **REQ:** 5 (kích hoạt VIP by code)
- **Priority:** P0 · **Severity:** HIGH · **Status:** ✅ done (2026-07-05)
- **Quyết định:** chọn **signed keys offline** (không backend — user xác nhận "không có backend").
- **Files:** SDK `vip/signed_vip_key.dart` (mới), `vip/vip_manager.dart` (`redeemSignedKey`), `utils/ad_preferences.dart` (redeemed kids), `applovin_admob_sdk.dart` (export), `tool/vip_keygen.dart` + `tool/vip_mint.dart` (mới), `pubspec.yaml` (+cryptography); host `vip_keys.dart`, `vip_screen.dart`, `splash_screen.dart`, `translations/*`

## Giải pháp đã chọn
HMAC bị loại (phải ship secret → decompile forge được). Dùng **Ed25519 bất đối xứng**: chỉ **public key** ship trong app; **private key** dùng để mint offline, không bao giờ ship ⇒ decompile KHÔNG forge được key mới. One-time-use toàn cục cần server (đã ghi rõ giới hạn); one-time-use **per-device** enforce bằng redeemed-kid store.

## Vấn đề (Why)
Validate VIP hiện **hoàn toàn local**: `vip_keys.dart` giữ map key→Duration **base64 (không mã hoá)**. Decompile APK/IPA là lấy được key và redeem **vô hạn**. `vipKeyValidator=null` còn chấp nhận mọi key (demo). Không an toàn cho production.

## Acceptance criteria
- [ ] `vipKeyValidator` được nối tới **backend** (vd Firebase Function/HTTPS) kiểm tra: key hợp lệ, chưa dùng (one-time-use) hoặc còn quota, (khuyến nghị) bind device/GAID.
- [ ] Redeem thành công mới trả `Duration` để `redeemVip` cấp; thất bại có thông báo rõ (invalid / đã dùng / hết quota / offline).
- [ ] Xử lý offline khi redeem: báo "cần mạng để kích hoạt" thay vì cấp mù.
- [ ] Không commit key thô; map local (nếu còn) chỉ để **test/debug**, chặn ở release (assert nếu validator local-only trong release).
- [ ] Tài liệu hoá hợp đồng validator trong `packages/ad_sdk/README.md`.

## Ghi chú kỹ thuật
- Giữ `redeemVip(stack:true)` cho gia hạn cộng dồn (đã có, clamp bởi `maxVipStackDuration`).
- Server nên trả duration chuẩn hoá; client không tự suy từ key.

## Test — `test/signed_vip_key_test.dart` (11 case, xanh)
- [x] Unit verify: key hợp lệ → duration+kid; tampered payload → reject; ký bằng key khác → reject; verify sai public key → reject; malformed/prefix sai/rỗng → reject; seconds<=0 → reject.
- [x] Integration redeem: hợp lệ → success + VIP active; cùng kid lần 2 → alreadyUsed; kid khác → stack; key rác → invalid, không cấp VIP.
- [x] Widget: nút Redeem key hợp lệ → status success + VIP active.

## Kết quả
- **255/255 test SDK xanh**, analyze SDK + host sạch.
- Host `vip_screen` redeem qua `redeemSignedKey`; `vip_keys.dart` chỉ còn public key + demo keys (bỏ base64 map thô).
- **Flip host path override** sang `packages/ad_sdk` (để host compile với API mới). ⚠️ **Nhớ flip lại** trước release (ghi trong pubspec + T02 note).
- Private key demo lưu ở scratchpad (KHÔNG commit). Production: chạy `vip_keygen.dart` tạo cặp mới, thay public key trong `vip_keys.dart`, cất private key vào secret manager.

## Giới hạn đã biết
One-time-use **toàn cục** (chống share key giữa nhiều máy) cần server — ngoài phạm vi offline. Đã enforce per-device + không forge được key mới. Nếu sau này có backend → nâng cấp thành server-validated (giữ nguyên API `redeemSignedKey` + thêm lớp kiểm tra online).
