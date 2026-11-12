# T277 — Script adb tái lập được cho smoke test thủ công (thay thao tác tay dễ sai)

- **Loại:** Tooling
- **Priority:** P2 · **Severity:** LOW
- **Status:** done-pending-review
- **Nguồn:** audit round 79. Nhiều lần "bad format" trong log là lỗi tự động hóa nhập liệu (không xóa ô, tọa độ cố định theo từng máy), phải thử lại; kết quả khó tái lập giữa TECNO (1080x2436) và S24U (1080x2340, density override).

## Việc cần làm
- Một script (đặt ở `doc/audit/tools/`, NGOÀI `packages/ad_sdk` nên không vào tarball pub.dev; không dùng `tool/` của package) lấy tọa độ từ `uiautomator dump` (không dùng tọa độ cố định), chạy: mở màn, redeem key từ file, đọc log theo thẻ, ghi log liên tục ra file, kiểm tra `FATAL EXCEPTION`/ANR.
- Không in giá trị key/CRL ra log; che IP LAN.
- Tự khôi phục cài đặt đã đổi (density, đồng hồ, Wi-Fi) kể cả khi lỗi giữa chừng.

## Tiêu chí hoàn thành
- Chạy được trên ít nhất một máy; mô tả giới hạn (S24U: dùng `--user 0`).
- Không thêm dependency vào SDK; không nằm trong tarball pub.dev (kiểm `dart pub publish --dry-run`).

## Kết quả (2026-11-12)
- Đã viết `doc/audit/tools/adb_smoke.sh` + `README.md`: lấy tọa độ từ `uiautomator dump`, log liên tục (chỉ xóa logcat một lần), `type_secret_and_submit` đọc key từ file và kiểm SDK có phản ứng (trả mã 2 nếu không), `redact_file`, `restore_device` (density/Wi-Fi/đồng hồ) dùng với `trap`.
- Chạy thử trên TECNO (app example gốc, không cài đè/xóa dữ liệu): mở màn theo nhãn, gõ key giả từ file -> SDK báo `bad format`, FATAL/ANR 0, máy được khôi phục.
- **Lỗi tìm ra khi chạy thử và đã sửa:** (1) `tap_xy` nhận hai số bị tách sai; (2) `find_center` cũ dùng một regex gộp nhiều node nên bỏ sót `content-desc` — viết lại đọc từng node; (3) `adbd` của Android tự ghi mọi `adb shell input text <giá trị>` vào logcat nên key gõ vào lọt vào log đã lưu — đã ghi cảnh báo và cho `redact_file` xóa; đã quét các bằng chứng đã commit: các dòng adbd cũ chỉ là `screencap`/`keyevent`/`tap`, không chứa giá trị gõ.
- Chưa làm: chạy trên S24U (cần `--user 0` cho `pm`), chạy trong CI, shellcheck (chưa cài).
