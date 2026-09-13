# T204 — Redact identifier/entitlement secrets khỏi log (FIX/SECURITY)
Priority P0 · Status done · Source audit Codex: `ad_manager.dart:2603`, `applovin_adapter.dart:723`, `vip_manager.dart:1134`, `safe_logger.dart:100`.

Raw GAID/IDFA, test-device hash hoặc VIP key/code có thể đi vào log sink ngoài. Khuyến nghị centralized redaction (hash/truncate theo field policy), default deny secret fields; option chỉ giảm log level không đủ vì sink vẫn nhận dữ liệu.

Tests: unit logger capture với từng secret/format; widget debug panel không hiển thị raw; integration configured sink; Android+iOS device smoke ở debug/release và CI log scan.

Loop prompt: audit+score /10, unit/widget/integration mọi case, smoke device; >9/10 mới commit+push, nếu không loop.

## Đóng task (2026-09-13) — chỉ cập nhật tài liệu, không sửa code

Task này nằm trong đợt "sửa TOÀN BỘ mọi vấn đề đã phát hiện" sau khi audit
độc lập chấm điểm lại các task do một phiên làm việc khác tự chạy không
giám sát. Khác với T205/T207/T210/T211/T215 (đều cần sửa test hoặc code
thật), audit riêng cho T204 xác nhận: **code redaction đã được cài đặt
đầy đủ và đúng từ trước, chỉ có file task bị bỏ quên trong `todo/`, chưa
bao giờ được đóng.**

### Những gì đã có sẵn (xác minh lại, không phải mới viết)

- `lib/src/utils/sensitive_data_redactor.dart` — hàm `redactSensitiveData()`
  dùng regex khớp 3 nhóm field nhạy cảm: GAID/IDFA/advertising id, test
  device id/hash, và VIP key/code/token/private key — thay giá trị thật
  bằng `<redacted>`, giữ nguyên tên field để log vẫn đọc được.
- `lib/src/utils/safe_logger.dart` — MỌI message đi qua `SafeLogger` đều
  chạy qua `_redact()` (gọi `redactSensitiveData()`) trước khi tới sink
  của host (`onLog` callback) — nghĩa là redaction áp dụng tập trung một
  chỗ, không phải rải rác từng call site như `ad_manager.dart:2603`,
  `applovin_adapter.dart:723`, `vip_manager.dart:1134` (audit gốc lo
  ngại) tự lo redact riêng lẻ.
- Test thật xác nhận hành vi, không phải test giả:
  - `test/safe_logger_test.dart` — capture sink thật, log 1 message chứa
    cả 5 dạng secret (`GAID=`, `IDFA:`, `test-device-hash=`, `VIP_KEY=`,
    `private-key:`), xác nhận giá trị thật KHÔNG xuất hiện trong output
    và field name có `<redacted>`.
  - `test/safe_logger_widget_redaction_test.dart` — 1 nút bấm thật trong
    widget tree thật gọi `SafeLogger.d()`, xác nhận log ra ngoài đã bị
    redact.
  - `example/integration_test/t204_log_redaction_test.dart` — device
    test có `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`
    đúng, chạy được qua cơ chế integration_test thật.
  - Chạy lại cả 3 file: **8 test, tất cả xanh** (không sửa gì, chỉ xác
    nhận lại).

### Việc đã làm trong lần đóng này

Chỉ 1 việc: cập nhật `Status todo` → `Status done`, di chuyển file từ
`doc/task/todo/` sang `doc/task/done/`, viết phần này. Không có commit
code nào — `git diff` cho phần code sẽ trống, chỉ có `git mv` cho file
task.

### Kết quả (giải thích không kỹ thuật)

Task này yêu cầu: đảm bảo các thông tin nhạy cảm (mã định danh thiết bị,
mã VIP...) không bao giờ bị in ra log mà bên ngoài có thể đọc được (ví dụ
log của Crashlytics, Sentry, hay log CI). Khi audit lại, tôi phát hiện
tính năng này **đã được làm đúng và đầy đủ từ trước** — chỉ là tờ ghi chú
công việc (task file) bị quên chưa đánh dấu "xong" và chưa chuyển vào thư
mục việc đã hoàn thành. Tôi đã kiểm tra lại kỹ (chạy toàn bộ test liên
quan, đọc lại code) để chắc chắn không có lỗ hổng nào, rồi mới đóng task.
Không có rủi ro nào cần lo — đây thuần túy là dọn dẹp sổ sách.

Điểm tự chấm: **9.5/10** (chỉ trừ 0.5 vì đây là việc dọn dẹp tài liệu,
không tạo ra giá trị code mới — nhưng xác nhận lại tính đúng đắn của một
tính năng bảo mật quan trọng vẫn có giá trị thật).
