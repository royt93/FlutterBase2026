# T278 — Privacy Options: hoàn tất đổi ý trong thời hạn 180 giây (bằng chứng còn thiếu)

- **Loại:** Verification (có người thao tác)
- **Priority:** P2 · **Severity:** MEDIUM
- **Status:** done (2026-11-12; chủ sản phẩm duyệt đóng task, giới hạn ghi trong mục Kết quả)
- **Nguồn:** audit round 79: lượt thử trên TECNO vượt 180 giây, SDK báo timeout, lựa chọn đến muộn vẫn được áp dụng lại. Chưa chứng minh luồng hoàn tất bình thường trong thời hạn.

## Việc cần làm
- Chạy với `UMP_EEA_DEBUG=true` + hash thiết bị, từ chối consent, mở Privacy Options, đổi sang Consent trong <60 giây, ghi log liên tục.
- Mong đợi: form đóng, trạng thái consent cập nhật, `nonPersonalizedAds` đổi, không timeout.

## Tiêu chí hoàn thành
- Log + ảnh lưu trong evidence; ghi rõ ai thao tác (người hay adb) và thời gian.
- Nếu vẫn timeout dù thao tác nhanh: ghi là lỗi cần điều tra, không đổi thành pass.

## Kết quả (2026-11-12, TECNO KJ7 Android 14, gói tạm `.t278test`)
- **Lần 1 (bỏ):** nhờ người bấm nhưng không ai bấm; form mở >15 phút: SDK báo `consent form dismiss timed out after 180s` rồi tự nhả chặn quảng cáo sau 15 phút. Không dùng làm bằng chứng luồng bình thường.
- **Lần 2 (dữ liệu sạch):** từ chối -> `consent=false`, `nonPersonalizedAds=true`; mở Privacy Options (form hiện lại); chọn Consent -> `privacy options done canRequestAds=true status=obtained`, `nonPersonalizedAds=false`, `consent=true`. Khoảng ~19 giây từ lúc bấm đến sự kiện hoàn tất (log), không có timeout.
- **Lưu ý quan trọng:** các nút trong form do ADB bấm theo toạ độ (người dùng yêu cầu tôi tự test), không phải thao tác người; thời gian là tốc độ adb. Không kiểm "Manage options", người dùng EEA thật, thiết bị khác.
- Bằng chứng: `doc/audit/evidence/round79_tecno_manual/t278/`.
