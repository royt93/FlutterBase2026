# T277 — Script adb tái lập được cho smoke test thủ công (thay thao tác tay dễ sai)

- **Loại:** Tooling
- **Priority:** P2 · **Severity:** LOW
- **Status:** todo
- **Nguồn:** audit round 79. Nhiều lần "bad format" trong log là lỗi tự động hóa nhập liệu (không xóa ô, tọa độ cố định theo từng máy), phải thử lại; kết quả khó tái lập giữa TECNO (1080x2436) và S24U (1080x2340, density override).

## Việc cần làm
- Một script `tool/` lấy tọa độ từ `uiautomator dump` (không dùng tọa độ cố định), chạy: mở màn, redeem key từ file, đọc log theo thẻ, ghi log liên tục ra file, kiểm tra `FATAL EXCEPTION`/ANR.
- Không in giá trị key/CRL ra log; che IP LAN.
- Tự khôi phục cài đặt đã đổi (density, đồng hồ, Wi-Fi) kể cả khi lỗi giữa chừng.

## Tiêu chí hoàn thành
- Chạy được trên ít nhất một máy; mô tả giới hạn (S24U: dùng `--user 0`).
- Không thêm dependency vào SDK; không nằm trong tarball pub.dev (kiểm `dart pub publish --dry-run`).
