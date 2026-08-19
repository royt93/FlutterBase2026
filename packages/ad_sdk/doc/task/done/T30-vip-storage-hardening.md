# T30 — VIP storage hardening: entries checksum + signed-key redeemed ledger (iOS Keychain)

- **REQ:** 5 (kích hoạt VIP by code, bảo mật không server)
- **Priority:** P1 · **Severity:** MEDIUM · **Status:** ✅ done (2026-07-10, SDK 1.0.24)
- **Files:** `utils/ad_preferences.dart` (`getVipEntriesRaw`/`setVipEntriesRaw`), `vip/_redeemed_key_ledger.dart` (mới), `vip/vip_manager.dart` (`redeemSignedKey`)

## Vấn đề (Why)
Audit partner-lead 2026-07-10 (finding #5) chỉ ra VIP entries lưu **plaintext JSON** trong SharedPreferences — sửa file trực tiếp trên máy đã root/jailbreak là tự cấp VIP miễn phí (không cần key). Ngoài ra, one-time-use của signed VIP key (T18) chỉ chặn qua `AdPreferences`, bị xoá khi uninstall/reinstall ⇒ redeem lại được cùng 1 key.

## Giải pháp đã chọn
- **Checksum FNV-1a** (không dùng `String.hashCode` vì không đảm bảo ổn định qua các bản Dart SDK; không dùng `cryptography` package's `Hmac` vì API async sẽ buộc `getVipEntriesRaw` thành async, lan ra mọi caller — không đáng cho một checksum có threat model là "răn đe sửa tay", không phải chống root thật). Lưu 1 key kết hợp `'<checksum>|<json>'` qua đúng 1 `setString` — tránh race ghi 2 key riêng.
- **Redeemed-key ledger** (`RedeemedKeyLedger`, iOS Keychain) bổ sung song song `AdPreferences`, sống sót qua uninstall/reinstall. Android không có backstop tương đương (cùng lý do với `FirstInstallGuard`: không có primitive local nào sống sót uninstall mà không cần plugin install-referrer). Fail-open: lỗi đọc/ghi Keychain → coi như "chưa dùng" (không khoá nhầm user hợp lệ vì lỗi storage).

## Acceptance criteria
- [x] Checksum mismatch → log cảnh báo + coi như không có data (không throw, không crash).
- [x] Data cũ (trước khi có checksum) vẫn đọc được, tự backfill checksum.
- [x] `redeemSignedKey` chặn double-redeem qua cả 2 lớp (`AdPreferences` + Keychain trên iOS).
- [x] Android: hành vi không đổi so với T18 (chỉ `AdPreferences`), có ghi rõ giới hạn.

## Test
- `test/ad_preferences_test.dart`: round-trip không đổi + case backfill checksum cho data cũ + case checksum bị sửa tay → trả `null`.
- `test/redeemed_key_ledger_test.dart` (mới): Keychain present/absent/tampered/read-error, Android no-op.

## Kết quả
SDK 1.0.24. `flutter analyze` clean (root + SDK). Test suite SDK xanh (số liệu cập nhật ở round audit tổng hợp — xem README `## Tiến độ`).

## Giới hạn đã biết
Checksum không chống được user có quyền root sửa cả checksum lẫn data cùng lúc (chỉ răn đe sửa tay đơn giản, đã nêu rõ trong audit gốc). Redeemed-key ledger one-time-use vẫn là **per-device**, không phải toàn cục — cùng giới hạn đã biết của T18 (cần server để chống share key giữa nhiều máy).
