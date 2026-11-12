# T275 — (Tuỳ chọn, cần chủ sản phẩm duyệt) Log gợi ý khi redeem mà CRL chưa từng được nạp

- **Loại:** SDK / Developer experience
- **Priority:** P3 · **Severity:** LOW
- **Status:** todo (đã đánh giá; chặn bởi trần size gate và cần duyệt sửa lib/)

## Bối cảnh
SDK không biết host cố ý bỏ CRL hay quên nối. Chỉ có thể log gợi ý, không phải lỗi, và không đổi hành vi redeem.

## Quyết định cần có trước khi làm
1. Chủ sản phẩm đồng ý thêm một dòng log (`SafeLogger.d`, một lần mỗi tiến trình) khi `redeemSignedKey` thành công mà `_revocationIssuedAt == null`.
2. Chạy `./tool/release_readiness_gate.sh size` trước/sau. Lib đo theo đúng cách gate đo (`git ls-files packages/ad_sdk/lib | du -k`) là **2048 KB = đúng trần** (số 2068 KB trước đó là `du -sk lib`, khác cách đo; gate vẫn pass tại 2026-11-12); nếu vượt trần thì rút gọn code khác, không nâng trần.

## Tiêu chí hoàn thành
- Test: có log lần đầu, không lặp lại, không có log khi đã nạp CRL, không đổi `SignedVipRedeemResult`.
- `CHANGELOG.md` có mục, golden API không đổi (không thêm API công khai).
- Không đổi quyết định đã được owner chấp nhận (redeem cần mạng; VIP dùng offline).

## Đánh giá khả thi (2026-11-12) — CHƯA sửa mã
- Chỗ chèn hợp lý: nhánh thành công của `redeemSignedKey` (`lib/src/vip/vip_manager.dart`, ngay trước `return SignedVipRedeemResult.success(entry)`), điều kiện `_revocationIssuedAt == null`.
- **Rào cản:** gate size đang ở đúng trần 2048 KB; `vip_manager.dart` là 93.817 byte, còn 391 byte trước khi `du -k` tăng thêm 4 KB (gate sẽ fail). Một dòng log có điều kiện + cờ "đã log" khoảng 250-400 byte: sát ngưỡng, rất dễ vượt.
- Muốn làm thì phải rút gọn một đoạn khác trong `lib/` trước (không nâng trần), và chủ sản phẩm phải duyệt việc sửa `lib/`. Lợi ích nhỏ (một dòng log debug), rủi ro không nhỏ (đụng trần gate, đụng đường redeem).
- **Đề xuất:** để task này ở `todo`, KHÔNG làm cho tới khi có lý do mạnh hơn; thay vào đó dùng example (T273) và tài liệu để nhắc partner nối CRL.
