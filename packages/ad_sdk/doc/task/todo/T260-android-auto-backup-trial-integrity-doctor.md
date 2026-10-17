# T260 — Tích Hợp Kiểm Tra Cấu Hình Android Auto Backup Vào Runtime Integration Doctor

- **Loại:** Enhancement / Security Hardening
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** todo (chuyển sang `inprogress/` khi làm, sang `done/` khi hoàn tất)

## Bối cảnh & Vấn đề

SDK áp dụng cơ chế 1-day VIP trial (dùng thử miễn phí 24 giờ không quảng cáo khi cài app lần đầu).
- Trên Android, do không có Keychain hệ thống và SDK không sử dụng server/backend, cơ chế chống gỡ cài đặt lại (anti-uninstall-bypass) phụ thuộc vào tính năng OS Auto Backup lưu trữ file `FlutterSharedPreferences.xml` (chứa cờ `_keyFirstInstallApplied`).
- Nhiều host app khi cấu hình Android 12+ thường thêm file `android/app/src/main/res/xml/data_extraction_rules.xml` hoặc `full_backup_content.xml` chứa quy tắc loại trừ (ví dụ `<exclude domain="sharedpref" path="."/>` để tránh backup dữ liệu đăng nhập nhạy cảm).
- Nếu host app vô tình loại trừ SharedPreferences, cờ trial sẽ bị xóa sạch mỗi khi người dùng gỡ app. Người dùng có thể liên tục gỡ ra cài lại để nhận 24 giờ không quảng cáo mãi mãi.

## Đề xuất giải pháp

1. Mở rộng `IntegrationDoctor` (`doctor.dart` / runtime self-check):
   - Thêm phương thức kiểm tra cảnh báo tích hợp Android Auto Backup: `checkAndroidBackupIntegrity()`.
   - Nếu phát hiện cấu hình backup của ứng dụng bị vô hiệu hóa (`allowBackup="false"` hoặc thiếu quy tắc include cho SharedPreferences), in ra hướng dẫn rõ ràng trong logcat ở chế độ debug/profile để lập trình viên biết và giữ lại file cờ trial.
2. Bổ sung helper script hoặc tài liệu hướng dẫn trong `doc/` về cấu hình XML chuẩn.

## Acceptance Criteria

- [ ] `IntegrationDoctor` phát hiện và cảnh báo nếu host app vô hiệu hóa Auto Backup gây hổng cơ chế 1-day trial.
- [ ] Không làm crash ứng dụng nếu host app cố tình tắt backup; chỉ ghi log cảnh báo rõ ràng.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Kiểm tra logic cảnh báo của doctor khi cung cấp các giả lập cấu hình backup khác nhau.
- **Integration test:** Chạy self-check trên Pixel 7 Pro và xác nhận kết quả kiểm tra được xuất ra đúng định dạng.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T260 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/doctor/doctor.dart, lib/src/vip/_first_install_guard.dart.
2. Viết test trước để kiểm tra các kịch bản cấu hình backup (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
