# T260 — Tích Hợp Kiểm Tra Cấu Hình Android Auto Backup Vào Runtime Integration Self-Check

- **Loại:** Enhancement / Security Hardening
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (ADVISORY ITEM IMPLEMENTED — PHẠM VI DART-LEVEL ADVISORY ĐÃ XÁC MINH TRÊN DEVICE)

## Kết quả triển khai & Xác minh (2026-10-18)

- `AdManager.runIntegrationSelfCheck()` trong `lib/src/core/ad_manager.dart` thêm item `Android Auto Backup config (trial integrity)`:
  - Non-Android: `skipped`, `not Android`.
  - Android + trial grace disabled: `skipped`, `firstInstallVipGrace is disabled`.
  - Android + grace enabled: `skipped` với advisory chỉ dẫn kiểm tra `data_extraction_rules.xml`, `full_backup_content.xml`, `FlutterSharedPreferences.xml` và README.
- Advisory luôn `skipped`: SDK là pure Dart, không thể đọc hoặc xác minh AndroidManifest/XML của host. Item không khẳng định Auto Backup đang bật, không ảnh hưởng `allPassed`, và không làm crash.
- Không đổi `SelfCheckStatus`/public API signature.
- Unit tests: `flutter test test/integration_self_check_test.dart` — **18/18 pass**, gồm non-Android, disabled grace, enabled grace và xác nhận advisory không làm self-check fail.
- Device integration: `flutter test integration_test/t193_self_check_already_ready_test.dart -d 2B051FDH3006MU --dart-define=AD_PROVIDER_ADMOB=true` trên Pixel 7 Pro — **pass**, xác nhận item có trong report và chứa hướng dẫn XML.
- `flutter analyze` — sạch; full `flutter test` — **2,724/2,724 pass**; `./tool/release_readiness_gate.sh api` — pass.
- `dart run tool/api_surface.dart` so với `test/goldens/public_api_surface.txt` — không đổi.

## Bối cảnh & Vấn đề

SDK áp dụng cơ chế 1-day VIP trial (dùng thử miễn phí 24 giờ không quảng cáo khi cài app lần đầu).
- Trên Android, do không có Keychain hệ thống và SDK không sử dụng server/backend, cơ chế chống gỡ cài đặt lại (anti-uninstall-bypass) phụ thuộc vào tính năng OS Auto Backup lưu trữ file `FlutterSharedPreferences.xml` (chứa cờ `_keyFirstInstallApplied`).
- Nhiều host app khi cấu hình Android 12+ thường thêm file `android/app/src/main/res/xml/data_extraction_rules.xml` hoặc `full_backup_content.xml` chứa quy tắc loại trừ (ví dụ `<exclude domain="sharedpref" path="."/>` để tránh backup dữ liệu đăng nhập nhạy cảm).
- Nếu host app vô tình loại trừ SharedPreferences, cờ trial sẽ bị xóa sạch mỗi khi người dùng gỡ app. Người dùng có thể liên tục gỡ ra cài lại để nhận 24 giờ không quảng cáo mãi mãi.

## Đề xuất giải pháp

1. **Phạm vi đã chốt (2026-10-18, user chấp nhận):** thêm một advisory item vào `AdManager.runIntegrationSelfCheck()` (`lib/src/core/ad_manager.dart`; `integration_self_check.dart` chỉ chứa kiểu dữ liệu). Item luôn `skipped` vì SDK là pure Dart, không đọc được AndroidManifest/XML của host app.
2. **Ngoài phạm vi:** phát hiện trạng thái backup thật (cần native MethodChannel — đã cân nhắc và không làm). Ghi nhận: host tắt backup vẫn không bị phát hiện, advisory chỉ nhắc kiểm tra.
3. Tài liệu XML backup chuẩn đã có sẵn trong `README.md` ("Android — required host-app configuration"); advisory trỏ về mục này.

## Acceptance Criteria

- [x] `AdManager.runIntegrationSelfCheck()` trong `lib/src/core/ad_manager.dart` có Android Auto Backup advisory cho trial bật; vì không đọc được XML host, item luôn `skipped` và yêu cầu host tự xác minh.
- [x] Advisory không làm crash ứng dụng hoặc khiến `SelfCheckResult.allPassed` fail.
- [x] `flutter analyze` sạch; full suite 2,724/2,724, self-check unit tests và Pixel 7 Pro integration test pass. Chưa có audit độc lập; self-check chỉ chạy ở debug build.

## Kế hoạch kiểm thử

- **Unit test:** Kiểm tra logic cảnh báo của self-check trong `test/integration_self_check_test.dart` khi cung cấp các giả lập cấu hình backup khác nhau.
- **Integration test:** Chạy self-check trên Pixel 7 Pro và xác nhận kết quả kiểm tra được xuất ra đúng định dạng.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T260 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/core/integration_self_check.dart, lib/src/vip/_first_install_guard.dart.
2. Viết test trước để kiểm tra các kịch bản cấu hình backup (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
