# T292 — Bộ đếm phiên bản cho kho VIP (phân biệt fallback mới hơn với fallback bị cắm vào)

- **Loại:** Fix (phần còn lại của một lỗi đã sửa một nửa)
- **Priority:** P2 · **Severity:** MEDIUM (chạm VIP đã trả tiền, nhưng hiếm và cần Keystore chập chờn)
- **Status:** todo — user đã chọn hướng "số phiên bản trong dữ liệu" (2026-11-23), chưa làm

## Bối cảnh & Vấn đề

Khi ghi vào secure storage thất bại nhưng đọc vẫn được, bản mới nằm ở fallback (`AdPreferences`) còn bản cũ nằm ở secure. `VipEntriesStore.getRaw()` luôn trả bản secure, nên lệnh thu hồi do hoàn tiền có thể sống lại, hoặc một khóa đã mua mất giá trị trong khi mã đã bị đánh dấu đã dùng ở sổ một-lần.

3.7.11 chỉ sửa được trường hợp **Keystore vẫn hỏng**: khi đó probe ghi thất bại nên fallback được ưu tiên. Review độc lập chỉ ra trường hợp còn lại: **Keystore tự phục hồi** trước lần đọc kế tiếp. Lúc đó probe thành công, và "fallback có mặt trong khi Keystore khỏe" giống hệt dấu hiệu giả mạo M6 (khóa bị cắm vào fallback), nên SDK trả bản secure cũ. Cùng một dấu hiệu, hai ý nghĩa.

Test tái hiện đã có và đang `skip`: `test/vip_entries_store_test.dart` → "a fallback newer than the secure copy survives a healed Keystore" (đỏ khi bỏ skip).

## Đề xuất giải pháp

Ghi một bộ đếm `revision` tăng dần vào JSON entries ở cả hai nơi (secure và fallback). Khi đọc, bản có revision lớn hơn thắng. Fallback không có revision hoặc revision thấp hơn vẫn bị coi là M6 (kẹp 24 giờ). Giữ tương thích ngược: dữ liệu cũ không có `revision` coi như 0.

Ràng buộc: `lib` đang đúng trần 2048KB (gate đo `du -k` theo từng file); `_vip_entries_store.dart` còn ~1KB dư, `vip_manager.dart` ~490 byte, `ad_preferences.dart` ~68 byte. Cần cắt chỗ khác nếu vượt.

## Acceptance Criteria

- [ ] Bỏ `skip` ở test trên và test xanh.
- [ ] Giả mạo M6 vẫn bị kẹp 24 giờ (test M6 hiện có vẫn xanh), kể cả khi kẻ tấn công cố gán `revision` lớn.
- [ ] Dữ liệu VIP cũ (không có `revision`) vẫn đọc được và không mất khóa nào.
- [ ] `flutter analyze` sạch, `flutter test` xanh, gate size xanh, CHANGELOG ghi rõ.
