# T275 — (Tuỳ chọn, cần chủ sản phẩm duyệt) Log gợi ý khi redeem mà CRL chưa từng được nạp

- **Loại:** SDK / Developer experience
- **Priority:** P3 · **Severity:** LOW
- **Status:** todo — **chặn bởi quyết định**: sửa `lib/`, đụng gate kích thước

## Bối cảnh
SDK không biết host cố ý bỏ CRL hay quên nối. Chỉ có thể log gợi ý, không phải lỗi, và không đổi hành vi redeem.

## Quyết định cần có trước khi làm
1. Chủ sản phẩm đồng ý thêm một dòng log (`SafeLogger.d`, một lần mỗi tiến trình) khi `redeemSignedKey` thành công mà `_revocationIssuedAt == null`.
2. Chạy `./tool/release_readiness_gate.sh size` trước/sau. Lib hiện 2068 KB (gate pass tại 2026-11-12); nếu vượt trần thì rút gọn code khác, không nâng trần.

## Tiêu chí hoàn thành
- Test: có log lần đầu, không lặp lại, không có log khi đã nạp CRL, không đổi `SignedVipRedeemResult`.
- `CHANGELOG.md` có mục, golden API không đổi (không thêm API công khai).
- Không đổi quyết định đã được owner chấp nhận (redeem cần mạng; VIP dùng offline).
