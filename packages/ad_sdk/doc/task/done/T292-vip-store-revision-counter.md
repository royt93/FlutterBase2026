# T292 — Bộ đếm phiên bản cho kho VIP (phân biệt fallback mới hơn với fallback bị cắm vào)

- **Loại:** Fix (phần còn lại của một lỗi đã sửa một nửa)
- **Priority:** P2 · **Severity:** MEDIUM (chạm VIP đã trả tiền, nhưng hiếm và cần Keystore chập chờn)
- **Status:** todo — CHỜ THIẾT KẾ. Hướng "số phiên bản trong dữ liệu" đã bị bỏ (2026-11-23) vì yếu hơn M6, xem mục "Vì sao hướng revision bị bỏ"

## Bối cảnh & Vấn đề

Khi ghi vào secure storage thất bại nhưng đọc vẫn được, bản mới nằm ở fallback (`AdPreferences`) còn bản cũ nằm ở secure. `VipEntriesStore.getRaw()` luôn trả bản secure, nên lệnh thu hồi do hoàn tiền có thể sống lại, hoặc một khóa đã mua mất giá trị trong khi mã đã bị đánh dấu đã dùng ở sổ một-lần.

3.7.11 chỉ sửa được trường hợp **Keystore vẫn hỏng**: khi đó probe ghi thất bại nên fallback được ưu tiên. Review độc lập chỉ ra trường hợp còn lại: **Keystore tự phục hồi** trước lần đọc kế tiếp. Lúc đó probe thành công, và "fallback có mặt trong khi Keystore khỏe" giống hệt dấu hiệu giả mạo M6 (khóa bị cắm vào fallback), nên SDK trả bản secure cũ. Cùng một dấu hiệu, hai ý nghĩa.

Test tái hiện đã có và đang `skip`: `test/vip_entries_store_test.dart` → "a fallback newer than the secure copy survives a healed Keystore" (đỏ khi bỏ skip).

## Vì sao hướng revision bị bỏ

Một bộ đếm `revision` trong JSON không được xác thực. Kẻ tấn công có root tự đặt `revision` cao hơn bản secure thì bản giả ở fallback "thắng" và thoát mức kẹp 24 giờ của M6. Nghĩa là sửa lỗi hiếm này bằng cách mở lại lỗ hổng giả mạo VIP. User đã đồng ý bỏ hướng này.

## Thiết kế đề xuất (2026-11-23, chưa code)

### Gốc của vấn đề

`setRaw` ghi secure; nếu thất bại thì ghi fallback và KHÔNG xóa bản secure cũ. Từ lúc đó có hai bản khác nhau, và chỉ "bản fallback tồn tại" cho biết bản nào mới, nhưng dấu hiệu đó trùng với dấu hiệu giả mạo M6 khi Keystore khỏe. Vấn đề không phải thiếu số phiên bản mà là **không bao giờ nên để hai bản lệch nhau mà không biết**.

### Phương án A (khuyến nghị): vá lệch ngay lúc ghi, bằng "xóa bản secure cũ khi ghi thất bại"

Trong `setRaw`, khi `_writeSecure` thất bại và ta ghi fallback, cố **xóa** (`_secure.delete`) bản secure cũ. Nếu xóa được thì không còn bản cũ để che: `getRaw` thấy secure rỗng và đi vào nhánh fallback đã có (với M6 kẹp 24 giờ nếu Keystore khỏe, đúng như hiện tại cho trường hợp "Keystore hỏng lúc cấp rồi lành"). Nếu xóa cũng thất bại (Keystore hỏng thật), chính là trường hợp bản 3.7.11 đã xử lý (probe thất bại, fallback thắng).
- Ưu: không đổi định dạng lưu, không thêm khóa, không thêm mã hóa, vài dòng, không làm yếu M6.
- Nhược: nếu ghi lỗi tạm thời nhưng xóa lại thành công, thì khách vẫn bị kẹp 24 giờ của M6 (nhẹ hơn mất toàn bộ, và là hành vi đã có). Còn một cửa sổ nhỏ: ghi fallback xong, xóa chưa chạy mà tiến trình chết; khi đó rơi vào đúng lỗi cũ nhưng hẹp hơn nhiều.

### Phương án B: ký bản fallback bằng khóa HMAC trong secure storage

Khóa ngẫu nhiên tạo lần đầu ghi được; fallback mang MAC; kẻ giả mạo không có khóa nên không giả được "mới hơn".
- Ưu: phân biệt "mới hơn thật" với "bị cắm vào" một cách có chứng minh.
- Nhược: không giải quyết khi Keystore hỏng từ lần ghi đầu (chưa có khóa); thêm mã ở vùng sát trần (`ad_preferences.dart` dư ~68 byte, `vip_manager.dart` ~490 byte); phức tạp hơn nhiều; cần review mật mã.

### Phương án C: ghi fallback trước, xác nhận secure rồi mới xóa fallback

Đảo thứ tự: luôn ghi fallback trước, rồi ghi secure, đọc lại so khớp, rồi mới xóa fallback. Không bao giờ có cửa sổ "bản mới chỉ ở fallback mà secure còn bản cũ".
- Ưu: loại bỏ lệch từ gốc.
- Nhược: fallback (kém tin cậy hơn, chỉ có checksum) luôn có mặt tạm thời với mọi lần ghi, mở rộng bề mặt M6; nhiều thao tác Keystore hơn mỗi lần ghi.

### Khuyến nghị

Làm A trước (nhỏ, an toàn nhất). Test đỏ đang `skip` (`healed Keystore`) cần đổi thành mô tả đúng: khi ghi secure thất bại và xóa thành công thì `getRaw` không trả bản cũ. Chỉ cân nhắc B nếu A không đủ.

## Đề xuất giải pháp (đã bị bỏ, giữ để tham khảo)

Ghi một bộ đếm `revision` tăng dần vào JSON entries ở cả hai nơi (secure và fallback). Khi đọc, bản có revision lớn hơn thắng. Fallback không có revision hoặc revision thấp hơn vẫn bị coi là M6 (kẹp 24 giờ). Giữ tương thích ngược: dữ liệu cũ không có `revision` coi như 0.

Ràng buộc: `lib` đang đúng trần 2048KB (gate đo `du -k` theo từng file); `_vip_entries_store.dart` còn ~1KB dư, `vip_manager.dart` ~490 byte, `ad_preferences.dart` ~68 byte. Cần cắt chỗ khác nếu vượt.

## Acceptance Criteria

- [ ] Bỏ `skip` ở test trên và test xanh.
- [ ] Giả mạo M6 vẫn bị kẹp 24 giờ (test M6 hiện có vẫn xanh), kể cả khi kẻ tấn công cố gán `revision` lớn.
- [ ] Dữ liệu VIP cũ (không có `revision`) vẫn đọc được và không mất khóa nào.
- [ ] `flutter analyze` sạch, `flutter test` xanh, gate size xanh, CHANGELOG ghi rõ.

## Hoàn thành 2026-11-24
Làm phương án A: `setRaw` khi ghi secure lỗi thì ghi fallback rồi `_secure.delete` bản cũ. Test `healed Keystore` bỏ skip và xanh; thêm test write+delete cùng lỗi vẫn trả fallback. 237 test VIP pass.
