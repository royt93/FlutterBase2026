# T278 — Privacy Options: hoàn tất đổi ý trong thời hạn 180 giây (bằng chứng còn thiếu)

- **Loại:** Verification (có người thao tác)
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** todo — cần người cầm máy
- **Nguồn:** audit round 79: lượt thử trên TECNO vượt 180 giây, SDK báo timeout, lựa chọn đến muộn vẫn được áp dụng lại. Chưa chứng minh luồng hoàn tất bình thường trong thời hạn.

## Việc cần làm
- Chạy với `UMP_EEA_DEBUG=true` + hash thiết bị, từ chối consent, mở Privacy Options, đổi sang Consent trong <60 giây, ghi log liên tục.
- Mong đợi: form đóng, trạng thái consent cập nhật, `nonPersonalizedAds` đổi, không timeout.

## Tiêu chí hoàn thành
- Log + ảnh lưu trong evidence; ghi rõ ai thao tác (người hay adb) và thời gian.
- Nếu vẫn timeout dù thao tác nhanh: ghi là lỗi cần điều tra, không đổi thành pass.
